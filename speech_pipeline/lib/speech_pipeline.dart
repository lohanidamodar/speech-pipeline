/// Streaming speech-to-speech pipeline: VAD → STT → LLM → TTS.
///
/// The engine interfaces in `engines.dart` are the contract; the sherpa-onnx
/// and OpenAI-compatible implementations are one binding of it. Swap any stage
/// without touching [SpeechPipeline].
library;

export 'src/audio.dart';
export 'src/anthropic_llm.dart';
export 'src/audiocpp_ffi.dart';
export 'src/cli_llm.dart';
export 'src/clone_engines.dart';
export 'src/clone_service.dart';
export 'src/engines.dart';
export 'src/kokoro_ipa_tts.dart';
export 'src/language_detect.dart';
export 'src/language_routing.dart';
export 'src/languages.dart';
export 'src/llm_discovery.dart';
export 'src/llm_providers.dart';
export 'src/local_models.dart';
export 'src/managed_server.dart';
export 'src/openai_llm.dart';
export 'src/orchestrator.dart';
export 'src/pipeline_setup.dart';
export 'src/sanskrit_phonemizer.dart';
export 'src/script_guard.dart';
export 'src/sherpa_init.dart';
export 'src/spoken_language_id.dart';
export 'src/sherpa_stt.dart';
export 'src/stt.dart';
export 'src/voice_library.dart';
export 'src/sherpa_tts.dart';
export 'src/sherpa_vad.dart';
