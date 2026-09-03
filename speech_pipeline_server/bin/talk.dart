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
      'voice-engine',
      help: 'Voice from the shared catalogue, downloaded on first use — '
          '"omnivoice-q8", "voxcpm2-q8". See --list-engines.',
    )
    ..addFlag(
      'list-engines',
      negatable: false,
      help: 'Print the available voices, their licences and sizes.',
    )
    ..addOption(
      'voice-model',
      help: 'GGUF for the cloning engine, bypassing the catalogue.',
    )
    ..addOption(
      'voice-style',
      help: 'Describe how the voice should sound — "an older man, unhurried". '
          'Only models that support voice design act on it.',
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

  final catalogue = VoiceCatalogue();
  if (args.flag('list-engines')) {
    _printVoices(catalogue);
    catalogue.dispose();
    return;
  }

  final language = PipelineLanguage.byCode(args.option('lang')!);

  // Starting the clone engine costs weight loading plus, on a GPU backend, a
  // one-off shader compilation — so it happens before anything else and its
  // cost is reported rather than hidden inside the first reply.
  // A voice named from the catalogue is fetched (with its licence shown) and
  // brings its own family name; an explicit --voice-model still wins, for a
  // build that is not in the catalogue yet.
  var modelPath = args.option('voice-model');
  var family = args.option('voice-family')!;
  VoiceSetup? voiceSetup;

  if (args.option('voice-engine') case final id? when modelPath == null) {
    final model = modelById(id);
    if (model == null) {
      stderr.writeln('No voice called "$id". Try --list-engines.');
      catalogue.dispose();
      exitCode = 1;
      return;
    }
    try {
      voiceSetup = await catalogue.prepare(
        model,
        onLicence: _confirmLicence,
        onProgress: _showProgress,
      );
    } on ModelDeclined catch (e) {
      stderr.writeln('$e');
      catalogue.dispose();
      exitCode = 1;
      return;
    }
    modelPath = voiceSetup.modelPath;
    family = voiceSetup.family;

    if (catalogue.languageWarning(model, args.option('lang')) case final w?) {
      stderr.writeln('\n$w\n');
    }
  }

  CloneService? clone;
  if (modelPath case final model?) {
    stderr.writeln('Starting the voice engine…');
    clone = await CloneService.start(
      modelPath: model,
      family: family,
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
  final style = args.option('voice-style');
  VoiceProfile? profile;
  if (ref != null) {
    profile = VoiceProfile(
      id: 'cli',
      name: ref.split(Platform.pathSeparator).last,
      referenceWavPath: ref,
      transcript: args.option('voice-ref-text'),
      instruct: style,
    );
  } else if (style != null && args.option('voice') == null) {
    // A voice that exists only as a description. No recording to clone from,
    // so the model is being asked to invent one.
    profile = VoiceProfile(id: 'designed', name: style, instruct: style);
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
    if (style != null) profile = profile.copyWith(instruct: style);
  }

  // Said rather than ignored: the string is accepted by every family and acted
  // on by only some, so silence here would look like the model obeying.
  if (style != null && voiceSetup != null && !voiceSetup.canDesignVoice) {
    stderr.writeln('note: ${voiceSetup.model.name} cannot be told how to '
        'sound; --voice-style will have no effect.\n');
  }
  if (style != null && voiceSetup == null && args.option('voice-model') != null) {
    stderr.writeln('note: --voice-model bypasses the catalogue, so how to '
        'deliver --voice-style is a guess. Use --voice-engine to be sure.\n');
  }

  final setup = PipelineSetup(
    language: language,
    autoLanguage: args.flag('auto-lang'),
    onLanguageDetected: (m) => stderr.writeln('· $m'),
    modelsDir: args.option('models'),
    nativeLibraryPath: args.option('native-lib'),
    cloneService: clone,
    voiceStylePolicy:
        voiceSetup?.stylePolicy ?? VoiceStylePolicy.instruction,
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

/// Lists the voices, what they can do, and what they are licensed under.
void _printVoices(VoiceCatalogue catalogue) {
  stdout.writeln('Voices — stored in ${catalogue.store.root.path}\n');
  for (final voice in catalogue.voices) {
    final can = [
      if (voice.canCloneVoice) 'clone',
      if (voice.canDesignVoice) 'design',
    ].join(', ');
    stdout
      ..writeln('${catalogue.has(voice) ? "installed" : "         "}  '
          '${voice.id.padRight(16)} ${voice.sizeLabel.padLeft(9)}  $can')
      ..writeln('            ${voice.licence.summary}')
      ..writeln('            ${voice.languages.contains("*") ? "any language" : voice.languages.join(" ")}');
    if (voice.notes case final notes?) {
      stdout.writeln('            $notes');
    }
    stdout.writeln();
  }
}

/// Shows the terms and waits, before a single byte is fetched.
///
/// These weights are somebody else's work under somebody else's terms.
/// Accepting them is the user's to do, not this program's.
bool _confirmLicence(VoiceModel model) {
  stderr
    ..writeln('\n${model.name} — ${model.sizeLabel}')
    ..writeln('  licence: ${model.licence.name}')
    ..writeln('  terms:   ${model.licence.url}')
    ..writeln('  source:  ${model.source}');
  if (model.licence.attribution case final credit?) {
    stderr.writeln('  credit:  $credit');
  }
  stderr.write('\nDownload it? [y/N] ');

  final answer = stdin.readLineSync()?.trim().toLowerCase();
  return answer == 'y' || answer == 'yes';
}

var _lastPercent = -1;

void _showProgress(DownloadProgress progress) {
  final percent = (progress.fraction * 100).round();
  if (percent == _lastPercent) return;
  _lastPercent = percent;
  // Carriage return rather than a new line: a gigabyte at one line per chunk
  // buries everything else that was on screen.
  stderr.write('\r  ${progress.file}  $percent%   ');
  if (percent == 100) stderr.writeln();
}
