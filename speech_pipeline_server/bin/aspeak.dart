import 'dart:io';

import 'package:args/args.dart';
import 'package:speech_pipeline/speech_pipeline.dart';

/// audio.cpp over FFI — synthesis and voice cloning, no subprocess.
///
///   dart run bin/aspeak.dart --model <gguf> --family omnivoice \
///     --lib ~/audio.cpp/build-pic/bin --text "नमस्ते" --out out.wav
///
/// With --repeat the model stays loaded across runs, which is the whole
/// argument for FFI: the CLI reloads 1.35 GB per utterance, this does not.
Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('model', mandatory: true)
    ..addOption('family', defaultsTo: 'omnivoice')
    ..addOption('lib', help: 'Directory holding libaudiocpp_c.*')
    ..addOption('text', mandatory: true)
    ..addOption('lang')
    ..addOption('instruct', help: 'Voice design prompt.')
    ..addOption('ref-wav', help: 'Reference audio to clone.')
    ..addOption('ref-text', help: 'Transcript of --ref-wav.')
    ..addOption(
      'backend',
      defaultsTo: 'cpu',
      allowed: ['cpu', 'cuda', 'vulkan', 'metal', 'hip', 'best'],
    )
    ..addOption('device', defaultsTo: '0')
    ..addOption('threads', defaultsTo: '8')
    ..addOption('out', defaultsTo: 'aspeak.wav')
    ..addOption(
      'repeat',
      defaultsTo: '1',
      help: 'Synthesise N times to show load is paid once.',
    );

  final args = parser.parse(argv);
  final backend = AcBackend.values.byName(args.option('backend')!);

  final loadStart = DateTime.now();
  final AudioCpp engine;
  try {
    engine = AudioCpp.open(
      modelPath: args.option('model')!,
      family: args.option('family')!,
      libraryPath: args.option('lib'),
      backend: backend,
      device: int.parse(args.option('device')!),
      threads: int.parse(args.option('threads')!),
    );
  } on AcException catch (e) {
    stderr.writeln('load failed: ${e.message}');
    exitCode = 1;
    return;
  }
  final loadMs = DateTime.now().difference(loadStart).inMilliseconds;
  stdout.writeln('${engine.version}  backend=${backend.name}');
  stdout.writeln('model loaded in ${loadMs}ms');

  final repeat = int.parse(args.option('repeat')!);
  final out = args.option('out')!;

  for (var i = 1; i <= repeat; i++) {
    final started = DateTime.now();
    final AcAudio audio;
    try {
      audio = engine.synthesize(
        args.option('text')!,
        language: args.option('lang'),
        instruct: args.option('instruct'),
        refWavPath: args.option('ref-wav'),
        refText: args.option('ref-text'),
      );
    } on AcException catch (e) {
      stderr.writeln('synthesis failed: ${e.message}');
      exitCode = 1;
      break;
    }
    final ms = DateTime.now().difference(started).inMilliseconds;
    final rtf = ms / 1000 / audio.seconds;
    final path = repeat == 1 ? out : out.replaceFirst('.wav', '_$i.wav');
    await File(path).writeAsBytes([
      ...wavHeader(
        sampleRate: audio.sampleRate,
        dataLength: audio.samples.length * 2,
      ),
      ...float32ToPcm16(audio.samples),
    ]);
    stdout.writeln(
      '  run $i: ${audio.seconds.toStringAsFixed(2)}s audio in '
      '${ms}ms  RTF ${rtf.toStringAsFixed(3)}  -> $path',
    );
  }

  engine.dispose();
}
