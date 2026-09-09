import 'dart:io';

import 'package:args/args.dart';
import 'package:speech_pipeline_server/clone_cli.dart';

/// Synthesises one line in a cloned voice and writes a .wav.
///
/// The one-shot counterpart to `clone_server.dart`: same engines, no server,
/// no browser. Written for callers that want a wav per line — a short's cards,
/// say — and a subprocess boundary rather than an HTTP one.
///
///   dart run bin/clone_say.dart --lang en --text "..." \
///     --ref ~/qwen3tts/ref_en.wav --out card-03.wav \
///     --llama-tts ~/llama.cpp/build/bin/llama-tts --qwen-dir ~/qwen3tts
Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('lang', defaultsTo: 'en', allowed: ['en', 'ne', 'sa'])
    ..addOption('text', mandatory: true)
    ..addOption('out', defaultsTo: 'say.wav')
    ..addOption('ref', help: 'Reference recording to clone from.')
    ..addOption('ref-text', defaultsTo: '', help: 'Its transcript. Required for ne/sa.')
    ..addOption('max-seconds', help: 'Generation budget. Estimated from the text if omitted.')
    ..addOption('llama-tts', help: 'Path to the llama-tts binary (English).')
    ..addOption('qwen-dir', help: 'Directory with the Qwen3-TTS GGUFs.')
    ..addOption('omnivoice', help: 'Path to omnivoice-tts (Nepali/Sanskrit).')
    ..addOption('omni-dir', help: 'Directory with the OmniVoice GGUFs.')
    ..addOption('steps', defaultsTo: '16', help: 'OmniVoice MaskGIT steps.')
    ..addFlag('trim', defaultsTo: true, help: 'Cut trailing near-silence.')
    ..addFlag('quiet', abbr: 'q', negatable: false)
    ..addFlag('help', abbr: 'h', negatable: false);

  final args = parser.parse(argv);
  if (args.flag('help')) {
    stdout.writeln('Synthesise one line in a cloned voice.\n');
    stdout.writeln(parser.usage);
    return;
  }

  final lang = args.option('lang')!;
  final text = args.option('text')!;
  final refText = args.option('ref-text')!;

  final engines = CloneEngines(
    llamaTts: args.option('llama-tts'),
    qwenDir: args.option('qwen-dir'),
    omnivoice: args.option('omnivoice'),
    omniDir: args.option('omni-dir'),
    steps: args.option('steps')!,
  );

  final blocker = cloneBlocker(engines, lang: lang, text: text, refText: refText);
  if (blocker != null) _fail(blocker);

  final ref = args.option('ref');
  if (ref == null || !File(ref).existsSync()) {
    _fail('A reference recording is required: --ref <file.wav>');
  }

  final budget =
      double.tryParse(args.option('max-seconds') ?? '') ?? estimateSeconds(text);
  final out = File(args.option('out')!);
  out.parent.createSync(recursive: true);

  final String exe;
  final List<String>? cmdArgs;
  String? stdinText;
  if (lang == 'en') {
    exe = engines.llamaTts!;
    cmdArgs = engines.englishArgs(ref, text, out.path, maxSeconds: budget);
  } else {
    final rt = File('${Directory.systemTemp.path}/clone_say_ref.txt')
      ..writeAsStringSync(refText);
    exe = engines.omnivoice!;
    cmdArgs = engines.indicArgs(lang, ref, rt.path, out.path, maxSeconds: budget);
    stdinText = text;
  }
  if (cmdArgs == null) _fail('Model files not found on disk.');

  final started = DateTime.now();
  final why = await runClone(
    exe: exe,
    args: cmdArgs,
    out: out,
    stdinText: stdinText,
  );
  if (why != null) _fail(why);

  final seconds =
      args.flag('trim') ? trimTrailingSilence(out) : wavDuration(out);

  if (!args.flag('quiet')) {
    final ms = DateTime.now().difference(started).inMilliseconds;
    stdout.writeln(
      '${out.path}  ${seconds.toStringAsFixed(2)}s  '
      '${out.lengthSync() ~/ 1024} KB  ${ms}ms',
    );
  }
}

Never _fail(String why) {
  stderr.writeln(why);
  exit(1);
}
