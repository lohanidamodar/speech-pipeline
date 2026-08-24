// C ABI for audio.cpp — enough surface for TTS and voice cloning from FFI.
//
// audio.cpp exposes a C++ API (ModelRegistry -> ILoadedVoiceModel ->
// IVoiceTaskSession). That is not callable from Dart, Go, or C#, so this
// wraps the offline TTS path in a flat, POD-only interface modelled on
// whisper.h / llama.h.
//
// Deliberately narrow: one model handle, one synthesis call, cloning by
// reference WAV. The engine covers 50 families; this covers the two we ship.
#ifndef AUDIOCPP_C_H
#define AUDIOCPP_C_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#  if defined(AC_BUILD_SHARED)
#    define AC_API __declspec(dllexport)
#  else
#    define AC_API __declspec(dllimport)
#  endif
#else
#  define AC_API __attribute__((visibility("default")))
#endif

typedef struct ac_context ac_context;

typedef enum {
    AC_BACKEND_CPU = 0,
    AC_BACKEND_CUDA = 1,
    AC_BACKEND_VULKAN = 2,
    AC_BACKEND_METAL = 3,
    AC_BACKEND_HIP = 4,
    AC_BACKEND_BEST = 5
} ac_backend;

typedef enum {
    AC_OK = 0,
    AC_ERR_LOAD = 1,
    AC_ERR_SESSION = 2,
    AC_ERR_SYNTH = 3,
    AC_ERR_ARGS = 4
} ac_status;

// Owned by the library; release with ac_audio_free.
typedef struct {
    float * samples;
    int     n_samples;
    int     sample_rate;
    int     channels;
} ac_audio;

typedef struct {
    const char * model_path;    // GGUF file or model package directory
    const char * family;        // e.g. "omnivoice", "qwen3_tts"
    ac_backend   backend;
    int          device;
    int          threads;
} ac_model_params;

typedef struct {
    const char * text;           // UTF-8. Never route this through a shell:
                                 // a non-UTF-8 console codepage silently
                                 // replaces non-ASCII with '?' and the model
                                 // will faithfully synthesise the damage.
    const char * language;       // may be NULL
    const char * instruct;       // voice design prompt, may be NULL
    const char * ref_wav_path;   // voice cloning reference, may be NULL
    const char * ref_text;       // transcript of ref_wav_path, may be NULL
} ac_tts_params;

AC_API void ac_model_default_params(ac_model_params * p);
AC_API void ac_tts_default_params(ac_tts_params * p);

// Loads the model and opens an offline TTS session. Returns NULL on failure;
// call ac_last_error for the reason.
AC_API ac_context * ac_init(const ac_model_params * params);
AC_API void         ac_free(ac_context * ctx);

// Synthesises into `out`. The context keeps weights resident, so repeated
// calls skip the load cost that dominates one-shot CLI runs.
AC_API ac_status ac_synthesize(ac_context * ctx, const ac_tts_params * params, ac_audio * out);

AC_API void ac_audio_free(ac_audio * audio);

// Last error on this thread, or "" when clean. Valid until the next call.
AC_API const char * ac_last_error(void);
AC_API const char * ac_version(void);

#ifdef __cplusplus
}
#endif
#endif // AUDIOCPP_C_H
