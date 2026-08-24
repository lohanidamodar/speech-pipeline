import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:speech_pipeline/speech_pipeline.dart';

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
    ..addOption('input', help: 'Raw 16 kHz mono s16le file. Defaults to stdin.')
    ..addOption(
      'output',
      help: 'Write a .wav here instead of streaming PCM to stdout.',
    )
    ..addOption(
      'lang',
      help: 'Conversation language, or the starting point for --auto-lang.',
      defaultsTo: 'en',
      allowed: ['en', 'ne', 'sa'],
    )
    ..addFlag(
      'realtime',
      negatable: false,
      help: 'Pace --input at speaking speed, as a microphone would.',
    )
    ..addFlag(
      'auto-lang',
      negatable: false,
      help: 'Detect the language each turn instead of fixing it.',
    )
    ..addOption('models', help: 'Model directory.', defaultsTo: 'models')
    ..addOption('native-lib', help: 'Directory holding libsherpa-onnx-c-api.*')
    ..addOption(
      'voice-model',
      help: 'GGUF for the cloning engine. Enables the cloned voice.',
    )
    ..addOption(
      'voice-lib',
      help: 'libaudiocpp_c file, or the directory holding it.',
    )
    ..addOption('voice-family', defaultsTo: 'omnivoice')
    ..addOption(
      'voice-backend',
      defaultsTo: 'best',
      allowed: ['cpu', 'cuda', 'vulkan', 'metal', 'hip', 'best'],
    )
    ..addOption(
      'voices-dir',
      help: 'Voice library directory. Defaults to <models>/voices.',
    )
    ..addOption(
      'voice',
      help: 'Name or id of a saved voice. Omit for the default speaker.',
    )
    ..addFlag('list-voices', negatable: false, help: 'Print saved voices.')
    ..addOption(
      'voice-ref',
      help: 'Reference .wav to clone from, bypassing the library.',
    )
    ..addOption(
      'voice-ref-text',
      help: 'What the reference recording says. Materially improves the clone.',
    )
    ..addFlag(
      'timing',
      help: 'Report per-stage latency for each turn.',
      negatable: false,
    )
    ..addFlag('help', abbr: 'h', negatable: false);

  final args = parser.parse(argv);
  if (args.flag('help')) {
    stderr.writeln('Usage: talk [options]\n${parser.usage}');
    return;
  }

  final language = PipelineLanguage.byCode(args.option('lang')!);

  // Starting the clone engine costs weight loading plus, on a GPU backend, a
  // one-off shader compilation — so it happens before anything else and its
  // cost is reported rather than hidden inside the first reply.
  CloneService? clone;
  if (args.option('voice-model') case final model?) {
    stderr.writeln('Starting the voice engine…');
    clone = await CloneService.start(
      modelPath: model,
      family: args.option('voice-family')!,
      libraryPath: args.option('voice-lib'),
      backend: AcBackend.values.byName(args.option('voice-backend')!),
      sttModelsDir: args.option('models'),
      sherpaLibraryPath: args.option('native-lib'),
    );
    stderr.writeln(
      '${clone.version} · warm-up ${clone.warmupMs}ms · '
      '${clone.sampleRate} Hz',
    );
  }

  final library = VoiceLibrary(
    Directory(args.option('voices-dir') ?? '${args.option('models')}/voices'),
  );
  await library.load();

  if (args.flag('list-voices')) {
    for (final v in library.profiles) {
      final detail = v.isCloned
          ? (v.hasTranscript ? '"${v.transcript}"' : 'no transcript')
          : "the model's own speaker";
      stderr.writeln('  ${v.id.padRight(18)} ${v.name}  ·  $detail');
    }
    await clone?.dispose();
    return;
  }

  // An explicit --voice-ref wins; otherwise a named voice from the library;
  // otherwise the model's own speaker, which always works.
  final ref = args.option('voice-ref');
  VoiceProfile? profile;
  if (ref != null) {
    profile = VoiceProfile(
      id: 'cli',
      name: ref.split(Platform.pathSeparator).last,
      referenceWavPath: ref,
      transcript: args.option('voice-ref-text'),
    );
  } else if (args.option('voice') case final wanted?) {
    profile =
        library.byId(wanted) ??
        library.profiles
            .where((v) => v.name.toLowerCase() == wanted.toLowerCase())
            .firstOrNull;
    if (profile == null) {
      stderr.writeln(
        'No voice "$wanted". Known: '
        '${library.profiles.map((v) => v.id).join(', ')}',
      );
      await clone?.dispose();
      exitCode = 1;
      return;
    }
  }

  final setup = PipelineSetup(
    language: language,
    autoLanguage: args.flag('auto-lang'),
    onLanguageDetected: (m) => stderr.writeln('· $m'),
    modelsDir: args.option('models'),
    nativeLibraryPath: args.option('native-lib'),
    cloneService: clone,
    onScriptRepair: (r) => stderr.writeln('\n· repaired script: ${r.summary}'),
    voiceProfile: profile,
  );

  if (setup.support.tts.caveat case final caveat?) {
    stderr.writeln('note: $caveat\n');
  }

  final SpeechPipeline pipeline;
  try {
    stderr.writeln(
      setup.autoLanguage
          ? 'Loading models for '
                '${setup.autoLanguages.map((l) => l.label).join(', ')}…'
          : 'Loading ${setup.language.label} models…',
    );
    pipeline = await setup.build();
  } on StateError catch (e) {
    stderr.writeln(e.message);
    exitCode = 1;
    return;
  }
  stderr.writeln('Ready. Output is ${pipeline.outputSampleRate} Hz mono.');

  final inputPath = args.option('input');
  final source = inputPath == null ? stdin : File(inputPath).openRead();

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

  final timing = args.flag('timing');
  // Measured from the end of the user's utterance, which is the moment they
  // start waiting. Time to first audio is the number that decides whether the
  // assistant feels responsive; total is only bookkeeping.
  var turnStart = DateTime.now();
  var spokenSamples = 0;
  Duration? toTranscript, toFirstToken, toFirstAudio;
  int since() => DateTime.now().difference(turnStart).inMilliseconds;

  final mic = args.flag('realtime')
      ? atRealTime(framePcm16(source))
      : framePcm16(source);

  await for (final event in pipeline.run(mic)) {
    switch (event) {
      case UserSpeaking():
        stderr.writeln('· listening');
      case UserFinishedSpeaking():
        turnStart = DateTime.now();
        toTranscript = null;
        toFirstToken = null;
        toFirstAudio = null;
        spokenSamples = 0;
      case UserTranscript(:final text):
        toTranscript = Duration(milliseconds: since());
        stderr.writeln('you  > $text');
      case AssistantDelta(:final text):
        toFirstToken ??= Duration(milliseconds: since());
        stderr.write(text);
      case AssistantAudio(:final samples):
        toFirstAudio ??= Duration(milliseconds: since());
        spokenSamples += samples.length;
        emitAudio(samples);
      case TurnComplete():
        stderr.writeln();
        if (timing) {
          final spoken = spokenSamples / pipeline.outputSampleRate;
          stderr.writeln(
            '  transcript ${toTranscript?.inMilliseconds ?? '-'}ms · '
            'first token ${toFirstToken?.inMilliseconds ?? '-'}ms · '
            'first audio ${toFirstAudio?.inMilliseconds ?? '-'}ms · '
            'turn ${since()}ms for '
            '${spoken.toStringAsFixed(1)}s of speech '
            '(RTF ${(since() / 1000 / (spoken == 0 ? 1 : spoken)).toStringAsFixed(2)})',
          );
        }
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
