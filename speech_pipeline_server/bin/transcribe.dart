import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:speech_pipeline/speech_pipeline.dart';
import 'package:speech_pipeline_server/setup.dart';

/// Transcribes a .wav file — a real recording, not synthesised speech.
///
/// This is the honest test of a recogniser. Round-tripping our own TTS flatters
/// it: the audio is clean, evenly paced, and in Sanskrit's case spoken by an
/// English voice the model never trained on.
///
///   dart run bin/transcribe.dart --lang ne --input recording.wav
Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('input', mandatory: true, help: 'Path to a .wav file.')
    ..addOption('lang', defaultsTo: 'en', allowed: ['en', 'ne', 'sa'])
    ..addOption('models', defaultsTo: 'models')
    ..addOption('native-lib')
    ..addFlag('whole',
        help: 'Skip the VAD and decode the file in one go.', negatable: false);

  final args = parser.parse(argv);
  final input = File(args.option('input')!);
  if (!input.existsSync()) {
    stderr.writeln('No such file: ${input.path}');
    exitCode = 1;
    return;
  }

  final setup = PipelineSetup(
    language: PipelineLanguage.byCode(args.option('lang')!),
    modelsDir: args.option('models'),
    nativeLibraryPath: args.option('native-lib'),
  );

  initSherpaBindings(setup.nativeLibraryPath);

  final wave = sherpa.readWave(input.path);
  if (wave.samples.isEmpty || wave.sampleRate == 0) {
    // readWave returns an empty result rather than throwing, which would
    // otherwise surface much later as a puzzling "no speech found".
    stderr.writeln(
      'Could not read ${input.path}.\n'
      'It must be a mono 16-bit PCM .wav — not .m4a, .mp3, or stereo, which is\n'
      'what phone recorders and Windows Voice Recorder usually produce.\n\n'
      'Convert with any of:\n'
      '  ffmpeg -i in.m4a -ac 1 -ar 16000 -c:a pcm_s16le out.wav\n'
      '  Audacity: Tracks > Mix > Stereo to Mono, then Export as WAV\n'
      '  online-audio-converter.com (pick WAV, mono)',
    );
    exitCode = 1;
    return;
  }

  final seconds = wave.samples.length / wave.sampleRate;
  stdout.writeln('${input.path}: ${seconds.toStringAsFixed(2)}s '
      '@ ${wave.sampleRate} Hz');
  stdout.writeln('${setup.language.label} — ${setup.activeSttModel}\n');

  final audio = resample(wave.samples, wave.sampleRate, kSampleRate);
  final stt = await setup.buildStt();

  if (args.flag('whole')) {
    final at = DateTime.now();
    final text = await stt.transcribe(audio);
    stdout.writeln('[whole file, ${_ms(at)}] $text');
    await stt.dispose();
    return;
  }

  final vad = SherpaVadEngine(model: '${setup.modelsDir}/silero_vad.onnx');
  // Trailing silence so the VAD closes the final segment.
  final padded = _concat([audio, Float32List(kSampleRate)]);

  var n = 0;
  await for (final event in vad.process(_frames(padded))) {
    if (event case SpeechEnded(:final samples)) {
      final at = DateTime.now();
      final text = await stt.transcribe(samples);
      stdout.writeln('[${++n}] ${(samples.length / kSampleRate)
          .toStringAsFixed(2)}s, ${_ms(at)}: $text');
    }
  }
  if (n == 0) stderr.writeln('VAD found no speech — is the recording silent?');

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
