import 'audio.dart';
import 'engines.dart';
import 'language_detect.dart';
import 'languages.dart';
import 'spoken_language_id.dart';

/// Speaks each reply with the voice for the language it is actually in.
///
/// This is not only for conversations that switch language. It fixes a plainer
/// bug: the reply's language is the model's choice, not the configuration's.
/// Ask an English-configured assistant something in Nepali and it may well
/// answer in Nepali — which the English voice then reads as gibberish.
///
/// Every voice has its own rate (Piper 22.05 kHz, Kokoro 24 kHz) but playback
/// is configured once from [sampleRate], so output is resampled to a single
/// declared rate rather than switching underneath the player.
class LanguageRoutingTtsEngine implements TtsEngine {
  LanguageRoutingTtsEngine._(this._engines, this._fallback, this.sampleRate);

  /// Builds the router over already-constructed engines.
  ///
  /// [fallback] is used when detection is not confident enough to act on —
  /// a two-word reply carries little evidence, and switching voices on a coin
  /// flip is worse than staying put.
  static LanguageRoutingTtsEngine over(
    Map<PipelineLanguage, TtsEngine> engines, {
    required PipelineLanguage fallback,
    int? sampleRate,
  }) {
    if (engines.isEmpty) {
      throw ArgumentError('Routing needs at least one voice.');
    }
    if (!engines.containsKey(fallback)) {
      throw ArgumentError('No voice for the fallback language $fallback.');
    }
    // The highest rate present: resampling up preserves what the voice
    // produced, where resampling everything down would throw part of it away.
    final rate =
        sampleRate ??
        engines.values.map((e) => e.sampleRate).reduce((a, b) => a > b ? a : b);
    return LanguageRoutingTtsEngine._(Map.of(engines), fallback, rate);
  }

  final Map<PipelineLanguage, TtsEngine> _engines;
  final PipelineLanguage _fallback;

  @override
  final int sampleRate;

  /// The language most recently spoken in. Detection defers to this when the
  /// evidence is thin, so a conversation does not flicker between voices.
  PipelineLanguage get current => _current;
  PipelineLanguage _current = PipelineLanguage.english;

  /// Notified whenever the voice changes, for a caption or a status line.
  void Function(PipelineLanguage, LanguageGuess)? onLanguageChanged;

  /// Which languages this router can actually speak.
  Iterable<PipelineLanguage> get languages => _engines.keys;

  /// Chooses the voice for [text], without synthesising.
  PipelineLanguage route(String text) {
    final guess = detectLanguage(text);
    // Only act on a confident guess for a language we have a voice for.
    if (guess.isConfident && _engines.containsKey(guess.language)) {
      return guess.language;
    }
    return _engines.containsKey(_current) ? _current : _fallback;
  }

  @override
  Stream<AudioChunk> synthesize(String text) async* {
    if (text.trim().isEmpty) return;

    final guess = detectLanguage(text);
    final picked = route(text);
    if (picked != _current) {
      _current = picked;
      onLanguageChanged?.call(picked, guess);
    }

    final engine = _engines[picked]!;
    await for (final chunk in engine.synthesize(text)) {
      yield engine.sampleRate == sampleRate
          ? chunk
          : resample(chunk, engine.sampleRate, sampleRate);
    }
  }

  /// Starts the next conversation from [language] rather than from whatever
  /// the last reply happened to be in.
  void reset(PipelineLanguage language) => _current = language;

  @override
  Future<void> dispose() async {
    await Future.wait(_engines.values.map((e) => e.dispose()));
  }
}

/// Picks the recogniser to use from the audio itself.
///
/// The audio has to be routed before there is any transcript to read, so this
/// leans on [SpokenLanguageId] — but only for the Latin-against-Indic split it
/// is actually accurate at. Which Devanagari language it was is settled later,
/// from the transcript, by [LanguageRoutingTtsEngine].
class LanguageRoutingSttEngine implements SttEngine {
  LanguageRoutingSttEngine({
    required Map<PipelineLanguage, SttEngine> engines,
    required this.identifier,
    required PipelineLanguage fallback,
    this.onLanguageDetected,
  }) : _engines = Map.of(engines),
       _fallback = fallback {
    if (!_engines.containsKey(fallback)) {
      throw ArgumentError('No recogniser for the fallback language $fallback.');
    }
  }

  final Map<PipelineLanguage, SttEngine> _engines;
  final SpokenLanguageId identifier;
  final PipelineLanguage _fallback;

  /// Reports the language the audio was routed to, and the raw Whisper code
  /// behind it — worth surfacing, because that code is often not the language.
  final void Function(PipelineLanguage, String raw)? onLanguageDetected;

  Iterable<PipelineLanguage> get languages => _engines.keys;

  @override
  Future<String> transcribe(AudioChunk samples) async {
    if (samples.isEmpty) return '';

    final raw = identifier.rawCode(samples);
    final guessed = identifier.identify(samples);
    final picked = guessed != null && _engines.containsKey(guessed)
        ? guessed
        : _fallback;
    onLanguageDetected?.call(picked, raw);

    return _engines[picked]!.transcribe(samples);
  }

  @override
  Future<void> dispose() async {
    identifier.dispose();
    await Future.wait(_engines.values.map((e) => e.dispose()));
  }
}
