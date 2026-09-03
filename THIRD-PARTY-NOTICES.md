# Third-party notices

This code is MIT (see `LICENSE`). It ships no binaries and no model weights —
it loads native libraries you supply and downloads models you choose — but what
it drives has its own terms, and they are not all the same.

## Native libraries it loads

| library | licence |
|---|---|
| [audio.cpp](https://github.com/0xShug0/audio.cpp) — synthesis, cloning, voice design | Apache-2.0 |
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) — recognition, voice activity | Apache-2.0 |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) | MIT |

## Models it can download

**No weights are included here.** They are fetched from their publishers
through [voice_models](https://github.com/lohanidamodar/voice-models), which
shows the licence before anything downloads. Their terms are the publishers',
not this project's:

| model | does | licence | what it asks |
|---|---|---|---|
| [OmniVoice](https://github.com/k2-fsa/OmniVoice) | speaks | Apache-2.0 | the notice |
| [VoxCPM2](https://huggingface.co/openbmb/VoxCPM2) | speaks | Apache-2.0 | the notice |
| [Parakeet TDT 0.6b v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) | recognises | [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/) | credit NVIDIA |
| [SenseVoice Small](https://huggingface.co/FunAudioLLM/SenseVoiceSmall) | recognises | [FunASR Model Open Source License Agreement v1.1](https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE) | Alibaba's own terms — **not an OSI-approved licence** |
| [Silero VAD](https://github.com/snakers4/silero-vad) | finds speech | MIT | the notice |

Other models this can be pointed at — IndicConformer, Kokoro, Piper voices,
Whisper — carry their own terms, which are yours to check if you use them.

## Dart packages

All BSD-3-Clause (the Dart project authors, and Halil Durmus for `win32`)
except `sherpa_onnx`, which is Apache-2.0.
