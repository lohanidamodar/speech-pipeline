import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:speech_pipeline/speech_pipeline.dart';
import 'package:speech_pipeline_server/setup.dart';

/// Local conversation loop over pipes — no platform audio plugin required.
///
/// Mic in, speaker out:
///   arecord -f S16_LE -r 16000 -c 1 -t raw \
///     | dart run bin/talk.dart \
///     | aplay -f S16_LE -r 24000 -c 1 -t raw
///
/// Replay a recording instead:
///   dart run bin/talk.dart --input sample.raw --output reply.wav
Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('input',
        help: 'Raw 16 kHz mono s16le file. Defaults to stdin.')
    ..addOption('output',
        help: 'Write a .wav here instead of streaming PCM to stdout.')
    ..addOption('lang',
        help: 'Conversation language.',
        defaultsTo: 'en',
        allowed: ['en', 'ne', 'sa'])
    ..addOption('models', help: 'Model directory.', defaultsTo: 'models')
    ..addOption('native-lib',
        help: 'Directory holding libsherpa-onnx-c-api.*')
    ..addFlag('help', abbr: 'h', negatable: false);

  final args = parser.parse(argv);
  if (args.flag('help')) {
    stderr.writeln('Usage: talk [options]\n${parser.usage}');
    return;
  }

  final setup = PipelineSetup(
    language: PipelineLanguage.byCode(args.option('lang')!),
    modelsDir: args.option('models'),
    nativeLibraryPath: args.option('native-lib'),
  );

  if (setup.support.tts.caveat case final caveat?) {
    stderr.writeln('note: $caveat\n');
  }

  final SpeechPipeline pipeline;
  try {
    stderr.writeln('Loading ${setup.language.label} models…');
    pipeline = await setup.build();
  } on StateError catch (e) {
    stderr.writeln(e.message);
    exitCode = 1;
    return;
  }
  stderr.writeln('Ready. Output is ${pipeline.outputSampleRate} Hz mono.');

  final inputPath = args.option('input');
  final source = inputPath == null
      ? stdin
      : File(inputPath).openRead();

  final outputPath = args.option('output');
  final captured = outputPath == null ? null : BytesBuilder(copy: false);

  void emitAudio(AudioChunk chunk) {
    final bytes = float32ToPcm16(chunk);
    if (captured != null) {
      captured.add(bytes);
    } else {
      stdout.add(bytes);
    }
  }

  await for (final event in pipeline.run(framePcm16(source))) {
    switch (event) {
      case UserSpeaking():
        stderr.writeln('· listening');
      case UserTranscript(:final text):
        stderr.writeln('you  > $text');
      case AssistantDelta(:final text):
        stderr.write(text);
      case AssistantAudio(:final samples):
        emitAudio(samples);
      case TurnComplete():
        stderr.writeln();
      case Interrupted():
        stderr.writeln('\n· interrupted');
      case PipelineError(:final error):
        stderr.writeln('\nerror: $error');
        exitCode = 1;
    }
  }

  if (captured != null && outputPath != null) {
    final data = captured.takeBytes();
    await File(outputPath).writeAsBytes([
      ...wavHeader(
        sampleRate: pipeline.outputSampleRate,
        dataLength: data.length,
      ),
      ...data,
    ]);
    stderr.writeln('Wrote $outputPath');
  }

  await pipeline.dispose();
  await stdout.flush();
}
