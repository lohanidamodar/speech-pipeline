import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'engines.dart';
import 'languages.dart';

/// Whisper's spoken-language identifier, narrowed to what this pipeline speaks.
///
/// **Measured accuracy matters more than the feature existing.** On five
/// samples through this pipeline it returned: English → `en` ✓, Nepali → `hi`
/// and `ne`, Sanskrit → `si` and `pa`. It never once said `sa`.
///
/// So it is used for the split it is actually good at — Latin-script European
/// against Indic — and not for telling Nepali from Sanskrit. Every error above
/// stayed inside the Indic family, which made that split correct 5 times out
/// of 5. Nepali and Sanskrit are separated afterwards, from the transcript,
/// where the written evidence is far stronger than the acoustic evidence.
class SpokenLanguageId {
  SpokenLanguageId._(this._sli);

  /// [encoder] and [decoder] must be a **multilingual** Whisper export; the
  /// `.en` models have no language tokens to choose between.
  factory SpokenLanguageId.open({
    required String encoder,
    required String decoder,
    int threads = 2,
  }) => SpokenLanguageId._(
    sherpa.SpokenLanguageIdentification(
      sherpa.SpokenLanguageIdentificationConfig(
        whisper: sherpa.SpokenLanguageIdentificationWhisperConfig(
          encoder: encoder,
          decoder: decoder,
        ),
        numThreads: threads,
      ),
    ),
  );

  final sherpa.SpokenLanguageIdentification _sli;

  /// The raw Whisper code, e.g. `en`, `hi`, `ne`, `si`.
  String rawCode(AudioChunk samples, {int sampleRate = kSampleRate}) {
    final stream = _sli.createStream()
      ..acceptWaveform(samples: samples, sampleRate: sampleRate);
    try {
      return _sli.compute(stream).lang;
    } finally {
      stream.free();
    }
  }

  /// English, or "some Indic language" — the only distinction this is
  /// trustworthy for. Null when Whisper returned something unrecognised.
  ///
  /// Returning Nepali for any Indic code is deliberate: it is the pipeline's
  /// conversational Devanagari language, and Sanskrit is settled from the
  /// transcript rather than from the audio.
  PipelineLanguage? identify(
    AudioChunk samples, {
    int sampleRate = kSampleRate,
  }) {
    final code = rawCode(samples, sampleRate: sampleRate).toLowerCase();
    if (code.isEmpty) return null;
    if (_indic.contains(code)) return PipelineLanguage.nepali;
    return PipelineLanguage.english;
  }

  /// Codes Whisper has been observed to return for Devanagari and neighbouring
  /// scripts. Sanskrit audio has come back as `si` and `pa`, so those count as
  /// Indic even though neither is a language this pipeline speaks.
  static const _indic = <String>{
    'ne',
    'hi',
    'sa',
    'mr',
    'bn',
    'gu',
    'pa',
    'si',
    'ta',
    'te',
    'kn',
    'ml',
    'or',
    'as',
    'ur',
    'sd',
  };

  void dispose() => _sli.free();
}
