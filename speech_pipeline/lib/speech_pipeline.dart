/// Streaming speech-to-speech pipeline: VAD → STT → LLM → TTS.
///
/// The engine interfaces in `engines.dart` are the contract; the sherpa-onnx
/// and OpenAI-compatible implementations are one binding of it. Swap any stage
/// without touching [SpeechPipeline].
library;

export 'src/audio.dart';
export 'src/audiocpp_ffi.dart';
export 'src/engines.dart';
export 'src/kokoro_ipa_tts.dart';
export 'src/languages.dart';
export 'src/openai_llm.dart';
export 'src/orchestrator.dart';
export 'src/sanskrit_phonemizer.dart';
export 'src/sherpa_init.dart';
export 'src/sherpa_stt.dart';
export 'src/sherpa_tts.dart';
export 'src/sherpa_vad.dart';
