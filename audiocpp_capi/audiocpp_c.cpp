#include "audiocpp_c.h"

#include "engine/framework/audio/wav_reader.h"
#include "engine/framework/core/backend.h"
#include "engine/framework/runtime/model.h"
#include "engine/framework/runtime/registry.h"
#include "engine/framework/runtime/session.h"

#ifdef _OPENMP
#include <omp.h>
#endif

#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <memory>
#include <string>
#include <vector>

namespace rt = engine::runtime;

namespace {

// Errors surface through a getter rather than the return value so callers can
// keep the flat status enum and still get a message worth logging.
thread_local std::string g_error;

void set_error(const std::string & msg) { g_error = msg; }

rt::AudioBuffer read_wav(const std::string & path) {
    const auto wav = engine::audio::read_wav_f32(std::filesystem::path(path));
    return rt::AudioBuffer{wav.sample_rate, wav.channels, wav.samples};
}

engine::core::BackendType to_backend(ac_backend b) {
    switch (b) {
        case AC_BACKEND_CUDA:   return engine::core::BackendType::Cuda;
        case AC_BACKEND_VULKAN: return engine::core::BackendType::Vulkan;
        case AC_BACKEND_METAL:  return engine::core::BackendType::Metal;
        case AC_BACKEND_HIP:    return engine::core::BackendType::Hip;
        case AC_BACKEND_BEST:   return engine::core::BackendType::BestAvailable;
        default:                return engine::core::BackendType::Cpu;
    }
}

}  // namespace

struct ac_context {
    rt::ModelRegistry registry;
    std::unique_ptr<rt::ILoadedVoiceModel> model;
    std::unique_ptr<rt::IVoiceTaskSession> session;
    rt::IOfflineVoiceTaskSession * offline = nullptr;
};

void ac_model_default_params(ac_model_params * p) {
    if (p == nullptr) return;
    *p = ac_model_params{};
    p->backend = AC_BACKEND_CPU;
    p->device = 0;
    p->threads = 4;
}

void ac_tts_default_params(ac_tts_params * p) {
    if (p == nullptr) return;
    *p = ac_tts_params{};
}

ac_context * ac_init(const ac_model_params * params) {
    if (params == nullptr || params->model_path == nullptr) {
        set_error("model_path is required");
        return nullptr;
    }
    try {
        auto ctx = std::make_unique<ac_context>();
        ctx->registry = rt::make_default_registry();

        rt::ModelLoadRequest load;
        load.model_path = params->model_path;
        if (params->family != nullptr && params->family[0] != '\0') {
            load.family_hint = params->family;
        }
        ctx->model = ctx->registry.load(load);

        rt::TaskSpec spec;
        spec.task = rt::VoiceTaskKind::Tts;
        spec.mode = rt::RunMode::Offline;

        rt::SessionOptions opts;
        opts.backend.type = to_backend(params->backend);
        opts.backend.device = params->device;
        const int threads = params->threads > 0 ? params->threads : 4;
        opts.backend.threads = threads;
#ifdef _OPENMP
        // ggml's CPU kernels parallelise through OpenMP, and its thread count
        // is process-global rather than part of SessionOptions. The CLI sets
        // both; setting only the backend field leaves OpenMP at its default
        // and costs ~30% on CPU.
        omp_set_num_threads(threads);
#endif

        ctx->session = ctx->model->create_task_session(spec, opts);
        ctx->offline = dynamic_cast<rt::IOfflineVoiceTaskSession *>(ctx->session.get());
        if (ctx->offline == nullptr) {
            set_error("model does not expose an offline TTS session");
            return nullptr;
        }
        g_error.clear();
        return ctx.release();
    } catch (const std::exception & e) {
        set_error(e.what());
        return nullptr;
    }
}

void ac_free(ac_context * ctx) { delete ctx; }

ac_status ac_synthesize(ac_context * ctx, const ac_tts_params * params, ac_audio * out) {
    if (ctx == nullptr || params == nullptr || out == nullptr) {
        set_error("null argument");
        return AC_ERR_ARGS;
    }
    if (params->text == nullptr || params->text[0] == '\0') {
        set_error("text is required");
        return AC_ERR_ARGS;
    }
    try {
        rt::TaskRequest req;
        rt::Transcript transcript;
        transcript.text = params->text;
        if (params->language != nullptr) transcript.language = params->language;
        req.text_input = std::move(transcript);

        if (params->instruct != nullptr && params->instruct[0] != '\0') {
            req.options["instruct"] = params->instruct;
        }
        if (params->ref_wav_path != nullptr && params->ref_wav_path[0] != '\0') {
            rt::VoiceCondition voice;
            rt::VoiceReference speaker;
            speaker.audio = read_wav(params->ref_wav_path);
            voice.speaker = std::move(speaker);
            req.voice = std::move(voice);
            // OmniVoice conditions on the reference transcript; without it the
            // clone degrades badly, so it travels as a request option exactly
            // as the CLI's --reference-text does.
            if (params->ref_text != nullptr && params->ref_text[0] != '\0') {
                req.options["reference_text"] = params->ref_text;
            }
        }

        ctx->session->prepare(rt::build_preparation_request(req));
        const auto result = ctx->offline->run(req);

        if (!result.audio_output.has_value()) {
            set_error("engine returned no audio");
            return AC_ERR_SYNTH;
        }
        const auto & buf = *result.audio_output;
        out->n_samples = static_cast<int>(buf.samples.size());
        out->sample_rate = buf.sample_rate;
        out->channels = buf.channels;
        out->samples = static_cast<float *>(std::malloc(buf.samples.size() * sizeof(float)));
        if (out->samples == nullptr) {
            set_error("out of memory");
            return AC_ERR_SYNTH;
        }
        std::memcpy(out->samples, buf.samples.data(), buf.samples.size() * sizeof(float));
        g_error.clear();
        return AC_OK;
    } catch (const std::exception & e) {
        set_error(e.what());
        return AC_ERR_SYNTH;
    }
}

void ac_audio_free(ac_audio * audio) {
    if (audio == nullptr) return;
    std::free(audio->samples);
    audio->samples = nullptr;
    audio->n_samples = 0;
}

const char * ac_last_error(void) { return g_error.c_str(); }
const char * ac_version(void) { return "audiocpp-c 0.1.0"; }
