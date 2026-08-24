/// Which language the pipeline listens and speaks in.
///
/// Support is uneven and the differences are load-bearing, so each entry
/// records what is actually available rather than pretending parity.
enum PipelineLanguage {
  english('en', 'English'),
  nepali('ne', 'Nepali'),
  sanskrit('sa', 'Sanskrit');

  const PipelineLanguage(this.code, this.label);

  final String code;
  final String label;

  static PipelineLanguage byCode(String code) => values.firstWhere(
        (l) => l.code == code,
        orElse: () => throw ArgumentError('Unknown language code: $code'),
      );
}

/// How well a stage is served for a given language.
enum SupportLevel {
  /// A dedicated model for this language, ready to use after `fetch_models.sh`.
  ready,

  /// A dedicated model exists but ships only as a gated NeMo checkpoint, so it
  /// needs a one-time export before the Dart side can load it.
  needsExport,

  /// Works, but through a model built for a related language or a multilingual
  /// model's long tail — expect wrong pronunciation or higher error rates.
  approximated,

  /// No usable local model.
  unavailable,
}

/// What a single stage can do for one language.
class StageSupport {
  const StageSupport({
    required this.level,
    required this.model,
    this.fallback,
    this.caveat,
  });

  final SupportLevel level;
  final String model;

  /// What runs instead until [model] is available, if anything.
  final String? fallback;

  /// Why the level is what it is, whenever it isn't [SupportLevel.ready].
  final String? caveat;
}

class LanguageSupport {
  const LanguageSupport({required this.stt, required this.tts});

  final StageSupport stt;
  final StageSupport tts;
}

const languageSupport = <PipelineLanguage, LanguageSupport>{
  PipelineLanguage.english: LanguageSupport(
    stt: StageSupport(
      level: SupportLevel.ready,
      model: 'SenseVoice (zh/en/ja/ko/yue)',
    ),
    tts: StageSupport(level: SupportLevel.ready, model: 'Kokoro v0.19'),
  ),
  PipelineLanguage.nepali: LanguageSupport(
    stt: StageSupport(
      level: SupportLevel.ready,
      model: 'AI4Bharat IndicConformer (ne)',
      fallback: 'Whisper --language ne',
      caveat: 'Needs tool/export_indicconformer.py --lang ne once (gated, so '
          'an HF_TOKEN and accepted terms). Far better than Whisper, which is '
          'measurably poor at Nepali. Not yet validated by a Nepali speaker on '
          'human audio: on synthesised input it returns anusvara as '
          'candrabindu (काठमाडौं -> काठमाडौँ), and it is unresolved whether '
          'that is the recogniser or the TTS it was fed.',
    ),
    tts: StageSupport(
      level: SupportLevel.ready,
      model: 'Piper ne_NP-chitwan-medium',
    ),
  ),
  PipelineLanguage.sanskrit: LanguageSupport(
    stt: StageSupport(
      level: SupportLevel.ready,
      model: 'AI4Bharat IndicConformer (sa)',
      fallback: 'Whisper --language sa',
      caveat: 'Same one-time gated export as Nepali. Verified against native '
          'Sanskrit TTS: phonemes come through intact, including retroflexes '
          'and conjuncts; the residual errors are word-boundary placement, '
          'which is what CTC without a language model does. Earlier poor '
          'results were the test audio (an English voice), not the model.',
    ),
    tts: StageSupport(
      level: SupportLevel.approximated,
      model: 'Kokoro + Sanskrit phonemizer (IPA direct)',
      caveat: 'Phonology is correct — the Devanagari phonemizer keeps the '
          'inherent vowel, assimilates anusvara to the following consonant '
          'class, and gives visarga its echo, none of which espeak-ng Hindi '
          'does. What it is not is chanting: the voice is an English Kokoro '
          'speaker, so there is no pitch accent and no vrtta. Good for '
          'conversational Sanskrit and UI prompts; for recitation, plug '
          'Vagdhenu in behind TtsEngine.',
    ),
  ),
};
