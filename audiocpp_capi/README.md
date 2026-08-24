# audiocpp_capi

A C ABI over [audio.cpp](https://github.com/0xShug0/audio.cpp), so its engine can
be driven from `dart:ffi` (or Go, C#, anything with a C FFI).

audio.cpp exposes a C++ API — `ModelRegistry` → `ILoadedVoiceModel` →
`IVoiceTaskSession` — which no FFI can call. These ~165 lines flatten the
offline TTS and voice-cloning path into POD structs and eight exported
functions, modelled on `whisper.h`/`llama.h`.

Because audio.cpp's runtime is model-agnostic, this one shim reaches every
family it supports: `omnivoice` (646 languages, cloning), `qwen3_tts`,
`fish_audio`, and the rest. Selecting one is a string, not new code.

## Applying it

The files live here so they survive the third-party checkout being deleted.
To build:

```bash
git clone --recurse-submodules https://github.com/0xShug0/audio.cpp
cp -r audiocpp_capi audio.cpp/capi
printf '\nadd_subdirectory(capi)\n' >> audio.cpp/CMakeLists.txt

# Linux (CPU). PIC is required — engine_runtime is static and will not
# otherwise link into a shared object.
cmake -S audio.cpp -B build -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON
cmake --build build --target audiocpp_c -j

# Windows + Vulkan (the fast path; needs the Vulkan SDK for headers + glslc)
cmake -S audio.cpp -B build-vk -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DENGINE_ENABLE_VULKAN=ON -DCMAKE_POSITION_INDEPENDENT_CODE=ON
cmake --build build-vk --target audiocpp_c
```

## Measured

Same Nepali sentence, same Q8_0 weights, RTX 4090 Laptop:

| path | RTF |
|---|---|
| omnivoice.cpp standalone, CPU | 6.69 |
| audio.cpp CLI, CPU | 4.78 |
| Dart FFI, CPU | 5.47 |
| audio.cpp CLI, Vulkan | 0.149 |
| **Dart FFI, Vulkan (warm)** | **0.129** |

The gap between a CLI and FFI is not the engine — it is that a subprocess pays
weight load *and* Vulkan pipeline compilation on every utterance. First call
after startup costs ~27 s of shader compilation; every call after is sub-second.
Warm the session once and keep it.

## Two traps

**Never pass text through a shell.** A non-UTF-8 console codepage silently
replaces non-ASCII with `?`, and the model faithfully synthesises the damage —
it looks like a broken model, not a broken pipe. FFI passes UTF-8 bytes and
sidesteps this entirely.

**PIC is mandatory on Linux.** Without it the link fails with
`relocation R_X86_64_TPOFF32 against __tls_guard`.
