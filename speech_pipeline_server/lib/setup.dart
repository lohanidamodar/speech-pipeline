import 'dart:io';

import 'package:speech_pipeline/speech_pipeline.dart';

/// Resolves model files laid out by `tool/fetch_models.sh` and builds a
/// configured pipeline. Everything is overridable by environment variable so
/// the same binary can point at other models without a rebuild.
class PipelineSetup {
  PipelineSetup({
    this.language = PipelineLanguage.english,
    String? modelsDir,
    String? nativeLibraryPath,
  })  : modelsDir =
            modelsDir ?? Platform.environment['SP_MODELS_DIR'] ?? 'models',
        nativeLibraryPath =
            nativeLibraryPath ?? Platform.environment['SP_NATIVE_LIB_DIR'];

  final PipelineLanguage language;
  final String modelsDir;

  /// Directory containing `libsherpa-onnx-c-api.so` / `.dylib` / `.dll`.
  /// Required for pure-Dart runs; a Flutter build resolves it via the plugin.
  final String? nativeLibraryPath;

  LanguageSupport get support => languageSupport[language]!;

  String get _vadModel => '$modelsDir/silero_vad.onnx';
  String get _senseVoiceDir =>
      '$modelsDir/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17';
  String get _indicConformerDir =>
      '$modelsDir/indicconformer-${language.code}';

  /// Whisper is multilingual and knows both `ne` and `sa`, so it is the
  /// stop-gap recogniser until a dedicated model has been exported.
  String get _whisperDir => Platform.environment['SP_WHISPER_DIR'] ??
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
        PipelineLanguage.english => support.stt.model,
        _ when hasDedicatedStt => support.stt.model,
        _ => 'Whisper $_whisperName (fallback, --language ${language.code})',
      };

  /// Fails loudly and early rather than surfacing an opaque native error.
  void verify() {
    final required = <String>[
      _vadModel,
      if (language == PipelineLanguage.english) ...[
        '$_senseVoiceDir/model.int8.onnx',
        '$_senseVoiceDir/tokens.txt',
        '$modelsDir/kokoro-en-v0_19/model.onnx',
        '$modelsDir/kokoro-en-v0_19/voices.bin',
        '$modelsDir/kokoro-en-v0_19/tokens.txt',
      ] else if (language == PipelineLanguage.sanskrit) ...[
        // Sanskrit reuses the English Kokoro bundle, driven from our own IPA.
        '$modelsDir/kokoro-en-v0_19/model.onnx',
        '$modelsDir/kokoro-en-v0_19/voices.bin',
        '$modelsDir/kokoro-en-v0_19/tokens.txt',
      ] else ...[
        '${_piperVoice.$1}/${_piperVoice.$2}.onnx',
        '${_piperVoice.$1}/tokens.txt',
      ],
    ];

    final missing = required.where((p) => !File(p).existsSync()).toList();
    if (missing.isNotEmpty) {
      throw StateError(
        'Missing model files:\n  ${missing.join('\n  ')}\n'
        'Run tool/fetch_models.sh, or set SP_MODELS_DIR.',
      );
    }

    if (!hasDedicatedStt && !_hasWhisper) {
      throw StateError(
        'No ${language.label} recogniser available.\n'
        '  ${support.stt.caveat}\n'
        'Either export the dedicated model to $_indicConformerDir/,\n'
        'or fetch a multilingual Whisper into $_whisperDir/ '
        '(tool/fetch_models.sh SP_STT=whisper).',
      );
    }
  }

  Future<SpeechPipeline> build() async {
    verify();

    // The VAD runs on this isolate, so the bindings must load here too.
    initSherpaBindings(nativeLibraryPath);
    final vad = SherpaVadEngine(model: _vadModel);

    final stt = await buildStt();
    final tts = await buildTts();

    final env = Platform.environment;
    final llm = OpenAiCompatibleLlm(
      baseUrl: env['SP_LLM_BASE_URL'] ?? 'https://api.openai.com/v1',
      model: env['SP_LLM_MODEL'] ?? 'gpt-4o-mini',
      apiKey: env['SP_LLM_API_KEY'],
    );

    return SpeechPipeline(
      vad: vad,
      stt: stt,
      llm: llm,
      tts: tts,
      systemPrompt: _systemPrompt,
    );
  }

  String get _systemPrompt =>
      'You are a voice assistant. Reply only in ${language.label}. '
      'Your replies are spoken aloud, so keep them short and conversational — '
      'usually one or two sentences. Do not use markdown, lists, or emoji.';

  SttConfig _sttConfig() => switch (language) {
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

    final int8 = File(part('encoder', '.int8')).existsSync() &&
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

  Future<SttEngine> buildStt() => SherpaSttEngine.spawn(_sttConfig());

  /// Sanskrit takes the IPA route into Kokoro; the others use sherpa's own
  /// text front-end, which is correct for their languages.
  Future<TtsEngine> buildTts() async {
    if (language == PipelineLanguage.sanskrit) {
      // Prefer the multi-lang pack: its Hindi voices are far closer to
      // Devanagari than the English-only bundle's speakers.
      final multi =
          Directory('$modelsDir/kokoro-multi-lang-v1_0').existsSync();
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
