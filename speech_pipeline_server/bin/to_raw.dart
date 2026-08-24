import 'dart:io';

import 'package:args/args.dart';
import 'package:speech_pipeline/speech_pipeline.dart';

/// Converts a .wav into the raw 16 kHz mono s16le that `talk.dart` reads.
///
///   dart run bin/to_raw.dart --in you.wav --out you.raw
///
/// [--pad] appends silence. The VAD only closes a turn once it has heard
/// enough quiet, so a file that ends the instant the speaker stops leaves the
/// last utterance open and nothing is ever transcribed.
Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('in', mandatory: true)
    ..addOption('out', mandatory: true)
    ..addOption('pad', defaultsTo: '1.0', help: 'Seconds of trailing silence.');

  final args = parser.parse(argv);
  final (samples, rate) = decodeWav(
    await File(args.option('in')!).readAsBytes(),
  );
  if (rate == 0 || samples.isEmpty) {
    stderr.writeln('Not a readable 16-bit WAV: ${args.option('in')}');
    exitCode = 1;
    return;
  }

  final resampled = resample(samples, rate, kSampleRate);
  final pad = (double.parse(args.option('pad')!) * kSampleRate).round();

  final out = File(args.option('out')!).openWrite()
    ..add(float32ToPcm16(resampled))
    ..add(List.filled(pad * 2, 0));
  await out.close();

  stderr.writeln(
    '${(resampled.length / kSampleRate).toStringAsFixed(2)}s '
    '@ $rate Hz → $kSampleRate Hz, +${args.option('pad')}s silence',
  );
}
