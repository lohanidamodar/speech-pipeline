import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:speech_pipeline/speech_pipeline.dart';
import 'package:speech_pipeline_server/setup.dart';

/// Speaks a phrase in the chosen language, then feeds the audio back through
/// VAD and STT to see what comes out.
///
/// Not an accuracy benchmark — TTS output is cleaner than a microphone and the
/// recogniser gets an easy ride. It is a wiring check: it proves the language's
/// whole native stack loads and round-trips, which is what breaks first.
Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('lang', defaultsTo: 'en', allowed: ['en', 'ne', 'sa'])
    ..addOption('text', help: 'Defaults to a per-language sample.')
    ..addOption('models', defaultsTo: 'models')
    ..addOption('native-lib');

  final args = parser.parse(argv);
  final language = PipelineLanguage.byCode(args.option('lang')!);
  final setup = PipelineSetup(
    language: language,
    modelsDir: args.option('models'),
    nativeLibraryPath: args.option('native-lib'),
  );

  const samples = {
    PipelineLanguage.english: 'The quick brown fox jumps over the lazy dog.',
    PipelineLanguage.nepali: 'नेपाल एक सुन्दर देश हो।',
    PipelineLanguage.sanskrit: 'अहं संस्कृतं वदामि।',
  };
  final text = args.option('text') ?? samples[language]!;

  try {
    setup.verify();
  } on StateError catch (e) {
    stderr.writeln(e.message);
    exitCode = 1;
    return;
  }

  stdout.writeln('${language.label}');
  stdout.writeln('  TTS: ${setup.support.tts.model}');
  stdout.writeln('  STT: ${setup.activeSttModel}');
  stdout.writeln('  text: "$text"');

  initSherpaBindings(setup.nativeLibraryPath);

  // --- speak ---------------------------------------------------------------
  var started = DateTime.now();
  final tts = await setup.buildTts();
  stdout.writeln('\nTTS loaded in ${_ms(started)}, ${tts.sampleRate} Hz');

  started = DateTime.now();
  final chunks = <AudioChunk>[];
  await for (final chunk in tts.synthesize(text)) {
    chunks.add(chunk);
  }
  final audio = _concat(chunks);

  if (audio.isEmpty) {
    stderr.writeln('FAIL: no audio produced.');
    exitCode = 1;
    await tts.dispose();
    return;
  }

  final seconds = audio.length / tts.sampleRate;
  final elapsed = DateTime.now().difference(started).inMilliseconds;
  stdout.writeln('  ${seconds.toStringAsFixed(2)}s of audio in ${elapsed}ms '
      '(RTF ${(elapsed / 1000 / seconds).toStringAsFixed(2)})');

  final wav = 'roundtrip-${language.code}.wav';
  await File(wav).writeAsBytes([
    ...wavHeader(sampleRate: tts.sampleRate, dataLength: audio.length * 2),
    ...float32ToPcm16(audio),
  ]);
  stdout.writeln('  wrote $wav');

  // --- listen --------------------------------------------------------------
  started = DateTime.now();
  final stt = await setup.buildStt();
  stdout.writeln('\nSTT loaded in ${_ms(started)}');

  final vad = SherpaVadEngine(model: '${setup.modelsDir}/silero_vad.onnx');
  final padded = _concat([
    Float32List(kSampleRate ~/ 2),
    resample(audio, tts.sampleRate, kSampleRate),
    Float32List(kSampleRate),
  ]);

  started = DateTime.now();
  var segments = 0;
  await for (final event in vad.process(_frames(padded))) {
    if (event case SpeechEnded(:final samples)) {
      segments++;
      final at = DateTime.now();
      final heard = await stt.transcribe(samples);
      stdout.writeln('  heard in ${_ms(at)}: "$heard"');
    }
  }

  if (segments == 0) {
    stderr.writeln('FAIL: VAD found no speech.');
    exitCode = 1;
  }

  await tts.dispose();
  await stt.dispose();
  await vad.dispose();
}

String _ms(DateTime since) =>
    '${DateTime.now().difference(since).inMilliseconds}ms';

Stream<AudioChunk> _frames(AudioChunk audio, {int size = 512}) async* {
  for (var i = 0; i < audio.length; i += size) {
    yield Float32List.sublistView(audio, i, (i + size).clamp(0, audio.length));
  }
}

AudioChunk _concat(List<AudioChunk> parts) {
  final out = Float32List(parts.fold(0, (n, p) => n + p.length));
  var offset = 0;
  for (final p in parts) {
    out.setAll(offset, p);
    offset += p.length;
  }
  return out;
}
