import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:speech_pipeline/speech_pipeline.dart';
import 'package:speech_pipeline_server/setup.dart';

/// Round-trips the native stages without touching the LLM: synthesise a known
/// sentence, feed the audio back through VAD and STT, and check what comes out.
///
/// This is the check that the FFI bindings, both worker isolates, and the
/// streaming callbacks all actually work on this machine.
Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('models', defaultsTo: 'models')
    ..addOption('native-lib')
    ..addOption('text',
        defaultsTo: 'The quick brown fox jumps over the lazy dog.')
    ..addOption('threads', defaultsTo: '2');
  final args = parser.parse(argv);

  final setup = PipelineSetup(
    modelsDir: args.option('models'),
    nativeLibraryPath: args.option('native-lib'),
  );

  try {
    setup.verify();
  } on StateError catch (e) {
    stderr.writeln(e.message);
    exitCode = 1;
    return;
  }

  initSherpaBindings(setup.nativeLibraryPath);

  // --- TTS -----------------------------------------------------------------
  stdout.writeln('Loading TTS…');
  var started = DateTime.now();
  final tts = await SherpaTtsEngine.spawn(
    TtsConfig.kokoro(
      model: '${setup.modelsDir}/kokoro-en-v0_19/model.onnx',
      voices: '${setup.modelsDir}/kokoro-en-v0_19/voices.bin',
      tokens: '${setup.modelsDir}/kokoro-en-v0_19/tokens.txt',
      dataDir: '${setup.modelsDir}/kokoro-en-v0_19/espeak-ng-data',
      numThreads: int.parse(args.option('threads')!),
      nativeLibraryPath: setup.nativeLibraryPath,
    ),
  );
  stdout.writeln('  loaded in ${_ms(started)}, ${tts.sampleRate} Hz output');

  final text = args.option('text')!;
  stdout.writeln('Synthesising: "$text"');
  started = DateTime.now();

  final chunks = <AudioChunk>[];
  Duration? firstChunkAt;
  await for (final chunk in tts.synthesize(text)) {
    firstChunkAt ??= DateTime.now().difference(started);
    chunks.add(chunk);
  }

  final audio = _concat(chunks);
  final durationSec = audio.length / tts.sampleRate;
  stdout.writeln('  ${chunks.length} chunks, '
      '${durationSec.toStringAsFixed(2)}s of audio');
  stdout.writeln('  time to first chunk: ${firstChunkAt!.inMilliseconds}ms');
  stdout.writeln('  total: ${_ms(started)} '
      '(RTF ${(DateTime.now().difference(started).inMilliseconds / 1000 / durationSec).toStringAsFixed(2)})');

  await File('selftest.wav').writeAsBytes([
    ...wavHeader(
      sampleRate: tts.sampleRate,
      dataLength: audio.length * 2,
    ),
    ...float32ToPcm16(audio),
  ]);
  stdout.writeln('  wrote selftest.wav');

  // --- VAD + STT -----------------------------------------------------------
  stdout.writeln('Loading STT…');
  started = DateTime.now();
  final stt = await SherpaSttEngine.spawn(
    SttConfig.senseVoice(
      model: '${setup.modelsDir}/'
          'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/model.int8.onnx',
      tokens: '${setup.modelsDir}/'
          'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/tokens.txt',
      nativeLibraryPath: setup.nativeLibraryPath,
    ),
  );
  stdout.writeln('  loaded in ${_ms(started)}');

  final vad = SherpaVadEngine(model: '${setup.modelsDir}/silero_vad.onnx');
  final resampled = resample(audio, tts.sampleRate, kSampleRate);

  // Pad with silence so the VAD sees a clean utterance boundary.
  final padded = _concat([
    Float32List(kSampleRate ~/ 2),
    resampled,
    Float32List(kSampleRate),
  ]);

  stdout.writeln('Recognising…');
  started = DateTime.now();
  var segments = 0;
  await for (final event in vad.process(_frames(padded))) {
    if (event case SpeechEnded(:final samples)) {
      segments++;
      final transcript = await stt.transcribe(samples);
      stdout.writeln('  segment $segments (${_ms(started)}): "$transcript"');
    }
  }

  if (segments == 0) {
    stderr.writeln('FAIL: VAD found no speech in the synthesised audio.');
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
    final end = (i + size).clamp(0, audio.length);
    yield Float32List.sublistView(audio, i, end);
  }
}

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
