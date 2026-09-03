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
    ..addOption(
      'engine',
      help: 'Voice from the shared catalogue — "omnivoice-q8", "voxcpm2-q8". '
          'Downloads on first use, licence shown first, and brings its own '
          'family name and style convention.',
    )
    ..addOption('model', help: 'GGUF path, bypassing the catalogue.')
    ..addOption('family', defaultsTo: 'omnivoice')
    ..addOption('lib', help: 'Directory holding libaudiocpp_c.*')
    ..addOption('text', mandatory: true)
    ..addOption('lang')
    ..addOption(
      'style',
      help: 'Describe the voice — "an older man, unhurried". Delivered the '
          'way the chosen model wants it.',
    )
    ..addOption(
      'instruct',
      help: 'Raw instruction field, for testing a family directly.',
    )
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

  // A catalogue entry knows its own family and how it wants a voice described;
  // an explicit --model leaves both to the caller.
  var modelPath = args.option('model');
  var family = args.option('family')!;
  var stylePolicy = VoiceStylePolicy.instruction;
  final catalogue = VoiceCatalogue();

  if (args.option('engine') case final id?) {
    final model = modelById(id);
    if (model == null) {
      stderr.writeln('No voice called "$id".');
      catalogue.dispose();
      exitCode = 1;
      return;
    }
    final setup = await catalogue.prepare(
      model,
      onLicence: (m) {
        stderr.writeln('${m.name} — ${m.sizeLabel} — ${m.licence.summary}');
        stderr.writeln(m.licence.url);
        stderr.write('Download it? [y/N] ');
        final a = stdin.readLineSync()?.trim().toLowerCase();
        return a == 'y' || a == 'yes';
      },
      onProgress: (p) => stderr.write('\r  ${(p.fraction * 100).round()}%   '),
    );
    modelPath = setup.modelPath;
    family = setup.family;
    stylePolicy = setup.stylePolicy;
  }

  if (modelPath == null) {
    stderr.writeln('Give --engine <id> or --model <gguf>.');
    catalogue.dispose();
    exitCode = 1;
    return;
  }

  // The description goes into the text for one family and into the instruction
  // field for another; a model handed it the wrong way says the line in its
  // default voice and reports success.
  final say = applyVoiceStyle(
    args.option('text')!,
    args.option('style'),
    stylePolicy,
  );

  final loadStart = DateTime.now();
  final AudioCpp engine;
  try {
    engine = AudioCpp.open(
      modelPath: modelPath,
      family: family,
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
        say.text,
        language: args.option('lang'),
        instruct: args.option('instruct') ?? say.instruct,
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
