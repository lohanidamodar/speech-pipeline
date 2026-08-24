import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:speech_pipeline/speech_pipeline.dart';

/// Synthesises one line of text with a chosen voice and writes a .wav.
///
/// Exists mainly to sanity-check a newly added language without standing up
/// the whole pipeline:
///   dart run bin/say.dart --lang ne --text "नमस्ते, तपाईंलाई कस्तो छ?"
Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('lang', defaultsTo: 'en', allowed: ['en', 'ne', 'sa'])
    ..addOption('text', mandatory: true)
    ..addOption('out', defaultsTo: 'say.wav')
    ..addOption('models', defaultsTo: 'models')
    ..addOption('native-lib')
    ..addOption('threads', defaultsTo: '4')
    ..addOption('voice', help: 'Kokoro voice index (Sanskrit).');

  final args = parser.parse(argv);
  final language = PipelineLanguage.byCode(args.option('lang')!);
  final support = languageSupport[language]!;
  final models = args.option('models')!;
  final threads = int.parse(args.option('threads')!);
  final nativeLib = args.option('native-lib');

  if (support.tts.caveat case final caveat?) {
    stderr.writeln('note: $caveat\n');
  }

  // Sanskrit goes through our own phonemizer straight into Kokoro; espeak's
  // only Devanagari voice is Hindi, which is what we are avoiding.
  if (language == PipelineLanguage.sanskrit) {
    await _saySanskrit(args, models, nativeLib);
    return;
  }

  initSherpaBindings(nativeLib);

  final config = switch (language) {
    PipelineLanguage.english => TtsConfig.kokoro(
      model: '$models/kokoro-en-v0_19/model.onnx',
      voices: '$models/kokoro-en-v0_19/voices.bin',
      tokens: '$models/kokoro-en-v0_19/tokens.txt',
      dataDir: '$models/kokoro-en-v0_19/espeak-ng-data',
      numThreads: threads,
      nativeLibraryPath: nativeLib,
    ),
    PipelineLanguage.nepali => _piper(
      models,
      'vits-piper-ne_NP-chitwan-medium',
      'ne_NP-chitwan-medium',
      threads,
      nativeLib,
    ),
    PipelineLanguage.sanskrit => throw StateError('handled above'),
  };

  final tts = await SherpaTtsEngine.spawn(config);
  final started = DateTime.now();

  final chunks = <AudioChunk>[];
  await for (final chunk in tts.synthesize(args.option('text')!)) {
    chunks.add(chunk);
  }

  final audio = _concat(chunks);
  if (audio.isEmpty) {
    stderr.writeln('FAIL: ${support.tts.model} produced no audio.');
    exitCode = 1;
    await tts.dispose();
    return;
  }

  final seconds = audio.length / tts.sampleRate;
  final elapsed = DateTime.now().difference(started).inMilliseconds;
  stdout.writeln('${support.tts.model} @ ${tts.sampleRate} Hz');
  stdout.writeln(
    '  ${seconds.toStringAsFixed(2)}s of audio in ${elapsed}ms '
    '(RTF ${(elapsed / 1000 / seconds).toStringAsFixed(2)})',
  );

  final out = args.option('out')!;
  await File(out).writeAsBytes([
    ...wavHeader(sampleRate: tts.sampleRate, dataLength: audio.length * 2),
    ...float32ToPcm16(audio),
  ]);
  stdout.writeln('  wrote $out');

  await tts.dispose();
}

TtsConfig _piper(
  String models,
  String dir,
  String name,
  int threads,
  String? nativeLib,
) => TtsConfig.vits(
  model: '$models/$dir/$name.onnx',
  tokens: '$models/$dir/tokens.txt',
  dataDir: '$models/$dir/espeak-ng-data',
  numThreads: threads,
  nativeLibraryPath: nativeLib,
);

AudioChunk _concat(List<AudioChunk> parts) {
  final total = parts.fold(0, (n, p) => n + p.length);
  final out = Float32List(total);
  var offset = 0;
  for (final p in parts) {
    out.setAll(offset, p);
    offset += p.length;
  }
  return out;
}

/// Devanagari → IPA → Kokoro, with no espeak-ng in the path.
Future<void> _saySanskrit(
  ArgResults args,
  String models,
  String? nativeLib,
) async {
  final text = args.option('text')!;
  final ipa = devanagariToIpa(text);
  stdout.writeln('IPA: $ipa');

  // The Hindi voices live only in the multi-lang pack; fall back to the
  // English bundle if it has not been fetched.
  final multi = Directory('$models/kokoro-multi-lang-v1_0').existsSync();
  final dir = multi
      ? '$models/kokoro-multi-lang-v1_0'
      : '$models/kokoro-en-v0_19';
  final voiceCount = multi ? 53 : 11;
  final names = multi ? kokoroMultiLangVoices : kokoroV019Voices;
  final voice = int.parse(
    args.option('voice') ?? (multi ? '$kokoroHindiMale' : '0'),
  );
  final vocab = KokoroVocabulary.fromFile('$dir/tokens.txt');
  final unknown = vocab.unknownSymbols(ipa);
  if (unknown.isNotEmpty) {
    stderr.writeln('warning: dropped symbols not in Kokoro vocab: $unknown');
  }

  final tts = await KokoroIpaTtsEngine.spawn(
    KokoroIpaConfig(
      model: '$dir/model.onnx',
      voices: '$dir/voices.bin',
      tokens: '$dir/tokens.txt',
      voiceIndex: voice,
      voiceCount: voiceCount,
      nativeLibraryPath: nativeLib,
    ),
  );

  final started = DateTime.now();
  final chunks = <AudioChunk>[];
  await for (final chunk in tts.synthesize(ipa)) {
    chunks.add(chunk);
  }

  final audio = _concat(chunks);
  if (audio.isEmpty) {
    stderr.writeln('FAIL: Kokoro produced no audio.');
    exitCode = 1;
    await tts.dispose();
    return;
  }

  final seconds = audio.length / tts.sampleRate;
  final elapsed = DateTime.now().difference(started).inMilliseconds;
  stdout.writeln(
    'Kokoro + Sanskrit phonemizer @ ${tts.sampleRate} Hz '
    '(voice ${names[voice]})',
  );
  stdout.writeln(
    '  ${chunks.length} chunk(s), '
    '${seconds.toStringAsFixed(2)}s of audio in ${elapsed}ms '
    '(RTF ${(elapsed / 1000 / seconds).toStringAsFixed(2)})',
  );

  final out = args.option('out')!;
  await File(out).writeAsBytes([
    ...wavHeader(sampleRate: tts.sampleRate, dataLength: audio.length * 2),
    ...float32ToPcm16(audio),
  ]);
  stdout.writeln('  wrote $out');
  await tts.dispose();
}
