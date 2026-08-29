import 'dart:io';

import 'clone_engines.dart';
import 'clone_service.dart';
import 'engines.dart';
import 'kokoro_ipa_tts.dart';
import 'language_routing.dart';
import 'languages.dart';
import 'llm_providers.dart';
import 'orchestrator.dart';
import 'sanskrit_phonemizer.dart';
import 'script_guard.dart';
import 'sherpa_init.dart';
import 'sherpa_stt.dart';
import 'sherpa_tts.dart';
import 'sherpa_vad.dart';
import 'spoken_language_id.dart';

/// Resolves model files laid out by `tool/fetch_models.sh` and builds a
/// configured pipeline. Everything is overridable by environment variable so
/// the same binary can point at other models without a rebuild.
class PipelineSetup {
  PipelineSetup({
    this.language = PipelineLanguage.english,
    String? modelsDir,
    String? nativeLibraryPath,
    this.llm,
    this.llmEngine,
    this.cloneService,
    this.voiceProfile,
    this.onScriptRepair,
    this.autoLanguage = false,
    this.onLanguageDetected,
  }) : modelsDir =
           modelsDir ?? Platform.environment['SP_MODELS_DIR'] ?? 'models',
       nativeLibraryPath =
           nativeLibraryPath ?? Platform.environment['SP_NATIVE_LIB_DIR'];

  final PipelineLanguage language;
  final String modelsDir;

  /// Which model answers. Defaults to [llmConfigFromEnvironment].
  final LlmConfig? llm;

  /// An engine built by the caller, used instead of [llm].
  ///
  /// For backends a [LlmConfig] cannot describe — a coding CLI, which has no
  /// base URL and no key because it is already authenticated.
  final LlmEngine? llmEngine;

  /// A running clone engine. When supplied, it replaces both the synthesiser
  /// and the recogniser: OmniVoice speaks in [voiceProfile]'s voice and the
  /// same isolate does recognition, so the native weights are loaded once
  /// rather than twice.
  final CloneService? cloneService;

  /// The voice to answer in. Null means the model's default speaker.
  final VoiceProfile? voiceProfile;

  bool get usesClonedVoice => cloneService != null;

  /// Notified when a reply had to be repaired before synthesis. See
  /// [ScriptGuardTtsEngine].
  final void Function(ScriptRepair)? onScriptRepair;

  /// Devanagari languages need the guard; English text never trips it.
  /// In auto mode a reply may be Devanagari whatever the starting language is.
  bool get _guardScript => autoLanguage || language != PipelineLanguage.english;

  /// Detect the language per turn instead of fixing it up front.
  ///
  /// [language] still matters: it is where the conversation starts and where
  /// detection falls back when the evidence is thin.
  final bool autoLanguage;

  /// Reports each routing decision — the language chosen, and why.
  final void Function(String message)? onLanguageDetected;

  /// Languages auto mode can move between. Sanskrit is included only when its
  /// recogniser has been exported, since there is no fallback for it.
  List<PipelineLanguage> get autoLanguages => [
    PipelineLanguage.english,
    PipelineLanguage.nepali,
    if (File('$modelsDir/indicconformer-sa/model.onnx').existsSync())
      PipelineLanguage.sanskrit,
  ];

  /// The model files a given language needs on disk.
  List<String> _modelsFor(PipelineLanguage l) => switch (l) {
    PipelineLanguage.english => [
      '$_senseVoiceDir/model.int8.onnx',
      '$_senseVoiceDir/tokens.txt',
      '$modelsDir/kokoro-en-v0_19/model.onnx',
      '$modelsDir/kokoro-en-v0_19/voices.bin',
      '$modelsDir/kokoro-en-v0_19/tokens.txt',
    ],
    // Sanskrit reuses the English Kokoro bundle, driven from our own IPA.
    PipelineLanguage.sanskrit => [
      '$modelsDir/kokoro-en-v0_19/model.onnx',
      '$modelsDir/kokoro-en-v0_19/voices.bin',
      '$modelsDir/kokoro-en-v0_19/tokens.txt',
    ],
    PipelineLanguage.nepali => [
      '${_piperVoice.$1}/${_piperVoice.$2}.onnx',
      '${_piperVoice.$1}/tokens.txt',
    ],
  };

  /// Multilingual Whisper, needed to route audio before there is a transcript.
  bool get _hasLanguageId =>
      File('$_whisperDir/$_whisperName-encoder.int8.onnx').existsSync() &&
      File('$_whisperDir/$_whisperName-decoder.int8.onnx').existsSync();

  PipelineSetup _forLanguage(PipelineLanguage other) => PipelineSetup(
    language: other,
    modelsDir: modelsDir,
    nativeLibraryPath: nativeLibraryPath,
    cloneService: cloneService,
    voiceProfile: voiceProfile,
  );

  /// Directory containing `libsherpa-onnx-c-api.so` / `.dylib` / `.dll`.
  /// Required for pure-Dart runs; a Flutter build resolves it via the plugin.
  final String? nativeLibraryPath;

  LanguageSupport get support => languageSupport[language]!;

  String get _vadModel => '$modelsDir/silero_vad.onnx';
  /// Parakeet TDT, when it has been fetched.
  ///
  /// Used in preference to SenseVoice for English, but the choice is closer
  /// than its reputation suggests. Measured on the same clip: Parakeet heard
  /// "thirty hands went up" where SenseVoice heard "30 he went up", and broke
  /// sentences better; SenseVoice heard "every single hand" where Parakeet
  /// heard "head". The clear difference is that SenseVoice normalises numbers
  /// to digits and Parakeet does not, so "thirty minutes" stays spelled out
  /// unless a cleanup pass converts it.
  ///
  /// Six times the size, and only used when present — downloading it is the
  /// opt-in.
  String get _parakeetDir =>
      Platform.environment['SP_PARAKEET_DIR'] ??
      '$modelsDir/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8';

  bool get hasParakeet =>
      File('$_parakeetDir/encoder.int8.onnx').existsSync() &&
      File('$_parakeetDir/joiner.int8.onnx').existsSync();

  String get _senseVoiceDir =>
      '$modelsDir/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17';
  String get _indicConformerDir => '$modelsDir/indicconformer-${language.code}';

  /// Whisper is multilingual and knows both `ne` and `sa`, so it is the
  /// stop-gap recogniser until a dedicated model has been exported.
  String get _whisperDir =>
      Platform.environment['SP_WHISPER_DIR'] ??
      '$modelsDir/sherpa-onnx-whisper-small';
  String get _whisperName =>
      _whisperDir.split('/').last.replaceFirst('sherpa-onnx-whisper-', '');

  /// Piper bundles name the model after the voice, not `model.onnx`.
  (String dir, String name) get _piperVoice => switch (language) {
    PipelineLanguage.nepali => (
      '$modelsDir/vits-piper-ne_NP-chitwan-medium',
      'ne_NP-chitwan-medium',
    ),
    _ => throw StateError('${language.label} does not use a Piper voice'),
  };

  /// True when the language-specific recogniser has been exported.
  bool get hasDedicatedStt =>
      language == PipelineLanguage.english ||
      File('$_indicConformerDir/model.onnx').existsSync();

  bool get _hasWhisper =>
      File('$_whisperDir/$_whisperName-encoder.onnx').existsSync() ||
      File('$_whisperDir/$_whisperName-encoder.int8.onnx').existsSync();

  /// What will actually recognise speech, given what is on disk.
  String get activeSttModel => switch (language) {
    PipelineLanguage.english when hasParakeet =>
      'Parakeet TDT 0.6b v3 (int8)',
    PipelineLanguage.english => support.stt.model,
    _ when hasDedicatedStt => support.stt.model,
    _ => 'Whisper $_whisperName (fallback, --language ${language.code})',
  };

  /// Fails loudly and early rather than surfacing an opaque native error.
  void verify() {
    // The clone engine brings its own weights and its own recogniser; only the
    // VAD still has to be on disk.
    if (usesClonedVoice) {
      if (!File(_vadModel).existsSync()) {
        throw StateError('Missing $_vadModel. Run tool/fetch_models.sh.');
      }
      if (voiceProfile case final v? when !v.hasTranscript) {
        stderr.writeln(
          'note: voice "${v.name}" has no reference transcript — '
          'OmniVoice conditions on it, so the clone will be weaker.',
        );
      }
      return;
    }

    // Auto mode loads every language's models at once, so all of them have to
    // be present — not just the one the conversation starts in.
    final required = <String>{
      _vadModel,
      if (autoLanguage)
        for (final l in autoLanguages) ..._forLanguage(l)._modelsFor(l)
      else
        ..._modelsFor(language),
    }.toList();

    if (autoLanguage && !_hasLanguageId) {
      throw StateError(
        'Auto language mode needs a multilingual Whisper to route audio.\n'
        'Expected int8 encoder and decoder in $_whisperDir/.\n'
        'Fetch one with: tool/fetch_models.sh SP_STT=whisper',
      );
    }

    final missing = required.where((p) => !File(p).existsSync()).toList();
    if (missing.isNotEmpty) {
      throw StateError(
        'Missing model files:\n  ${missing.join('\n  ')}\n'
        'Run tool/fetch_models.sh, or set SP_MODELS_DIR.',
      );
    }

    for (final l in autoLanguage ? autoLanguages : [language]) {
      final setup = l == language ? this : _forLanguage(l);
      if (!setup.hasDedicatedStt && !setup._hasWhisper) {
        throw StateError(
          'No ${l.label} recogniser available.\n'
          '  ${languageSupport[l]!.stt.caveat}\n'
          'Either export the dedicated model to ${setup._indicConformerDir}/,\n'
          'or fetch a multilingual Whisper into $_whisperDir/ '
          '(tool/fetch_models.sh SP_STT=whisper).',
        );
      }
    }
  }

  Future<SpeechPipeline> build() async {
    verify();

    // The VAD runs on this isolate, so the bindings must load here too.
    initSherpaBindings(nativeLibraryPath);
    final vad = SherpaVadEngine(model: _vadModel);

    final stt = await buildStt();
    final tts = await buildTts();

    return SpeechPipeline(
      vad: vad,
      stt: stt,
      llm: llmEngine ?? buildLlm(llm ?? llmConfigFromEnvironment()),
      tts: tts,
      systemPrompt: _systemPrompt,
    );
  }

  String get _systemPrompt {
    // In auto mode the reply's language is the user's choice, turn by turn, so
    // the prompt must not pin it to one.
    final rule = autoLanguage
        ? 'Always reply in the same language the user just used.'
        : 'Reply only in ${language.label}.';
    return 'You are a voice assistant. $rule '
        'Your replies are spoken aloud, so keep them short and conversational — '
        'usually one or two sentences. Do not use markdown, lists, or emoji.';
  }

  SttConfig _sttConfig() => switch (language) {
    PipelineLanguage.english when hasParakeet => SttConfig.transducer(
      encoder: '$_parakeetDir/encoder.int8.onnx',
      decoder: '$_parakeetDir/decoder.int8.onnx',
      joiner: '$_parakeetDir/joiner.int8.onnx',
      tokens: '$_parakeetDir/tokens.txt',
      nativeLibraryPath: nativeLibraryPath,
    ),
    PipelineLanguage.english => SttConfig.senseVoice(
      model: '$_senseVoiceDir/model.int8.onnx',
      tokens: '$_senseVoiceDir/tokens.txt',
      nativeLibraryPath: nativeLibraryPath,
    ),
    _ when hasDedicatedStt => SttConfig.nemoCtc(
      model: '$_indicConformerDir/model.onnx',
      tokens: '$_indicConformerDir/tokens.txt',
      nativeLibraryPath: nativeLibraryPath,
    ),
    _ => _whisperConfig(),
  };

  /// Uses int8 only when *both* halves are quantised — sherpa expects a
  /// matched pair, and the published bundles do not always ship both.
  SttConfig _whisperConfig() {
    String part(String name, String suffix) =>
        '$_whisperDir/$_whisperName-$name$suffix.onnx';

    final int8 =
        File(part('encoder', '.int8')).existsSync() &&
        File(part('decoder', '.int8')).existsSync();
    final suffix = int8 ? '.int8' : '';

    return SttConfig.whisper(
      encoder: part('encoder', suffix),
      decoder: part('decoder', suffix),
      tokens: '$_whisperDir/$_whisperName-tokens.txt',
      language: language.code,
      nativeLibraryPath: nativeLibraryPath,
    );
  }

  Future<SttEngine> buildStt() async {
    if (cloneService case final service?) {
      return CloneSttEngine(service, language: language.code);
    }
    if (!autoLanguage) return SherpaSttEngine.spawn(_sttConfig());

    final engines = <PipelineLanguage, SttEngine>{};
    for (final l in autoLanguages) {
      engines[l] = await SherpaSttEngine.spawn(_forLanguage(l)._sttConfig());
    }
    return LanguageRoutingSttEngine(
      engines: engines,
      identifier: SpokenLanguageId.open(
        encoder: '$_whisperDir/$_whisperName-encoder.int8.onnx',
        decoder: '$_whisperDir/$_whisperName-decoder.int8.onnx',
      ),
      fallback: language,
      onLanguageDetected: (l, raw) => onLanguageDetected?.call(
        'heard ${l.label}${raw == l.code ? '' : ' (whisper: $raw)'}',
      ),
    );
  }

  /// Sanskrit takes the IPA route into Kokoro; the others use sherpa's own
  /// text front-end, which is correct for their languages.
  Future<TtsEngine> buildTts() async {
    final engine = autoLanguage && cloneService == null
        ? await _buildRoutingVoice()
        : await _buildVoice();
    if (!_guardScript) return engine;
    return ScriptGuardTtsEngine(engine, onRepair: onScriptRepair);
  }

  /// One voice per language, chosen per reply.
  ///
  /// A cloned voice does not need this: it speaks whatever it is given, so
  /// only the language id handed to the engine changes.
  Future<TtsEngine> _buildRoutingVoice() async {
    final voices = <PipelineLanguage, TtsEngine>{};
    for (final l in autoLanguages) {
      voices[l] = await _forLanguage(l)._buildVoice();
    }
    final router = LanguageRoutingTtsEngine.over(voices, fallback: language)
      ..reset(language);
    router.onLanguageChanged = (l, guess) =>
        onLanguageDetected?.call('speaking ${l.label} · $guess');
    return router;
  }

  Future<TtsEngine> _buildVoice() async {
    if (cloneService case final service?) {
      return CloneTtsEngine(
        service,
        profile: voiceProfile,
        language: language.code,
      );
    }
    if (language == PipelineLanguage.sanskrit) {
      // Prefer the multi-lang pack: its Hindi voices are far closer to
      // Devanagari than the English-only bundle's speakers.
      final multi = Directory('$modelsDir/kokoro-multi-lang-v1_0').existsSync();
      final dir = multi
          ? '$modelsDir/kokoro-multi-lang-v1_0'
          : '$modelsDir/kokoro-en-v0_19';
      final kokoro = await KokoroIpaTtsEngine.spawn(
        KokoroIpaConfig(
          model: '$dir/model.onnx',
          voices: '$dir/voices.bin',
          tokens: '$dir/tokens.txt',
          voiceIndex: multi ? kokoroHindiMale : 0,
          voiceCount: multi ? 53 : 11,
          nativeLibraryPath: nativeLibraryPath,
        ),
      );
      return PhonemizingTtsEngine(kokoro, devanagariToIpa);
    }
    return SherpaTtsEngine.spawn(_ttsConfig());
  }

  TtsConfig _ttsConfig() {
    if (language == PipelineLanguage.english) {
      return TtsConfig.kokoro(
        model: '$modelsDir/kokoro-en-v0_19/model.onnx',
        voices: '$modelsDir/kokoro-en-v0_19/voices.bin',
        tokens: '$modelsDir/kokoro-en-v0_19/tokens.txt',
        dataDir: '$modelsDir/kokoro-en-v0_19/espeak-ng-data',
        nativeLibraryPath: nativeLibraryPath,
      );
    }
    final (dir, name) = _piperVoice;
    return TtsConfig.vits(
      model: '$dir/$name.onnx',
      tokens: '$dir/tokens.txt',
      dataDir: '$dir/espeak-ng-data',
      nativeLibraryPath: nativeLibraryPath,
    );
  }
}

/// Reads an [LlmConfig] from the environment.
///
/// `SP_LLM_PROVIDER` names an entry in [llmProviders]; the rest override that
/// entry's defaults. Setting only `SP_LLM_BASE_URL` — the original knob, from
/// when llama.cpp was the sole target — still works and is read as a custom
/// OpenAI-compatible endpoint.
LlmConfig llmConfigFromEnvironment([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  final baseUrl = env['SP_LLM_BASE_URL'];
  final id =
      env['SP_LLM_PROVIDER'] ??
      (baseUrl != null && baseUrl.isNotEmpty ? 'custom' : 'openai');

  final provider = llmProviderById(id);
  if (provider == null) {
    throw StateError(
      'Unknown SP_LLM_PROVIDER "$id". '
      'Known: ${llmProviders.map((p) => p.id).join(', ')}.',
    );
  }

  return LlmConfig(
    provider: provider,
    model: env['SP_LLM_MODEL'],
    apiKey: env['SP_LLM_API_KEY'],
    baseUrl: baseUrl,
    maxTokens: int.tryParse(env['SP_LLM_MAX_TOKENS'] ?? '') ?? 512,
  );
}
