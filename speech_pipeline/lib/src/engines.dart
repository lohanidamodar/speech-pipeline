import 'dart:typed_data';

/// Sample rate every stage of the pipeline agrees on. sherpa-onnx models are
/// trained at 16 kHz; resampling happens at the audio-source boundary only.
const int kSampleRate = 16000;

/// A chunk of mono PCM, normalised to [-1.0, 1.0].
typedef AudioChunk = Float32List;

/// One turn in the conversation history handed to the LLM.
class Message {
  const Message(this.role, this.content);

  const Message.system(this.content) : role = 'system';
  const Message.user(this.content) : role = 'user';
  const Message.assistant(this.content) : role = 'assistant';

  final String role;
  final String content;

  Map<String, dynamic> toJson() => {'role': role, 'content': content};
}

/// Speech recogniser. Implementations receive a complete utterance — turn
/// segmentation is the [VadEngine]'s job, not the recogniser's.
abstract interface class SttEngine {
  Future<String> transcribe(AudioChunk samples);
  Future<void> dispose();
}

/// Streaming text generator. Yields token deltas, not whole responses, so the
/// TTS stage can start on the first sentence instead of the last.
abstract interface class LlmEngine {
  Stream<String> respond(List<Message> history);
  Future<void> dispose();
}

/// Speech synthesiser. Yields audio as it is generated so playback can begin
/// before the full utterance is rendered.
abstract interface class TtsEngine {
  /// Output rate of the loaded voice — Kokoro is 24 kHz, most Piper 22.05 kHz.
  /// Playback must honour this rather than assuming [kSampleRate].
  int get sampleRate;

  Stream<AudioChunk> synthesize(String text);
  Future<void> dispose();
}

/// Applies a text transform before handing off to another engine.
///
/// The orchestrator only ever has text, but engines that skip a built-in
/// grapheme-to-phoneme front-end need phonemes. This keeps that conversion out
/// of both the pipeline and the engine.
class PhonemizingTtsEngine implements TtsEngine {
  const PhonemizingTtsEngine(this._inner, this._phonemize);

  final TtsEngine _inner;
  final String Function(String) _phonemize;

  @override
  int get sampleRate => _inner.sampleRate;

  @override
  Stream<AudioChunk> synthesize(String text) =>
      _inner.synthesize(_phonemize(text));

  @override
  Future<void> dispose() => _inner.dispose();
}

/// Turn segmenter. Consumes a continuous mic stream and emits one event per
/// detected utterance boundary.
abstract interface class VadEngine {
  /// Emits [SpeechStarted] as soon as speech is detected (used for barge-in)
  /// and [SpeechEnded] carrying the full utterance once silence follows.
  Stream<VadEvent> process(Stream<AudioChunk> audio);
  Future<void> dispose();
}

sealed class VadEvent {
  const VadEvent();
}

/// Speech onset. Fires before the utterance is complete — this is the signal
/// that lets the pipeline interrupt itself mid-answer.
final class SpeechStarted extends VadEvent {
  const SpeechStarted();
}

final class SpeechEnded extends VadEvent {
  const SpeechEnded(this.samples);
  final AudioChunk samples;
}
