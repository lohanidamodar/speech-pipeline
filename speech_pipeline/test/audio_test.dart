import 'dart:math' as math;
import 'dart:typed_data';

import 'package:speech_pipeline/speech_pipeline.dart';
import 'package:test/test.dart';

Float32List tone(double hz, int rate, double seconds) {
  final n = (rate * seconds).round();
  return Float32List.fromList([
    for (var i = 0; i < n; i++) math.sin(2 * math.pi * hz * i / rate),
  ]);
}

/// Correlates against a reference tone — a cheap single-bin DFT.
double energyAt(Float32List x, double hz, int rate) {
  var re = 0.0, im = 0.0;
  for (var i = 0; i < x.length; i++) {
    final phase = 2 * math.pi * hz * i / rate;
    re += x[i] * math.cos(phase);
    im += x[i] * math.sin(phase);
  }
  return math.sqrt(re * re + im * im) / x.length;
}

void main() {
  group('resample', () {
    test('passes a tone well inside the band', () {
      final input = tone(1000, 24000, 0.5);
      final out = resample(input, 24000, 16000);

      expect(out.length, closeTo(16000 * 0.5, 2));
      expect(energyAt(out, 1000, 16000), greaterThan(0.4));
    });

    test('rejects a tone above the target Nyquist instead of aliasing it', () {
      // 10 kHz at 24 kHz would fold to 6 kHz at 16 kHz if left unfiltered.
      final input = tone(10000, 24000, 0.5);
      final out = resample(input, 24000, 16000);

      expect(energyAt(out, 6000, 16000), lessThan(0.02),
          reason: 'aliased image should be suppressed');
    });

    test('linear interpolation would have aliased — proving the filter works',
        () {
      final input = tone(10000, 24000, 0.5);
      final ratio = 24000 / 16000;
      final naive = Float32List((input.length / ratio).floor());
      for (var i = 0; i < naive.length; i++) {
        final pos = i * ratio;
        final low = pos.floor();
        final high = math.min(low + 1, input.length - 1);
        final frac = pos - low;
        naive[i] = input[low] * (1 - frac) + input[high] * frac;
      }

      expect(energyAt(naive, 6000, 16000), greaterThan(0.2),
          reason: 'the naive path really does fold 10 kHz down to 6 kHz');
    });

    test('holds amplitude steady across the signal, including the edges', () {
      final out = resample(tone(440, 22050, 0.3), 22050, 16000);
      final head = out.sublist(0, 200).map((v) => v.abs()).reduce(math.max);
      final mid = out
          .sublist(out.length ~/ 2, out.length ~/ 2 + 200)
          .map((v) => v.abs())
          .reduce(math.max);

      expect(head, closeTo(mid, 0.15));
    });

    test('upsamples without changing pitch', () {
      final out = resample(tone(500, 16000, 0.4), 16000, 24000);
      expect(out.length, closeTo(24000 * 0.4, 2));
      expect(energyAt(out, 500, 24000), greaterThan(0.4));
    });

    test('is a no-op when the rates match', () {
      final input = tone(300, 16000, 0.05);
      expect(identical(resample(input, 16000, 16000), input), isTrue);
    });
  });

  group('pcm round-trip', () {
    test('survives float → int16 → float within quantisation error', () {
      final input = tone(440, 16000, 0.05);
      final back = pcm16ToFloat32(float32ToPcm16(input));

      expect(back.length, input.length);
      for (var i = 0; i < input.length; i++) {
        // Encoding scales by 32767 and decoding by 32768, so worst-case error
        // is a touch over one LSB rather than exactly one.
        expect(back[i], closeTo(input[i], 2 / 32767));
      }
    });
  });

  group('framePcm16', () {
    test('regroups ragged byte chunks into fixed frames', () async {
      final pcm = float32ToPcm16(tone(440, 16000, 0.5));
      // Sizes deliberately unaligned to the frame boundary.
      final ragged = <List<int>>[];
      for (var i = 0; i < pcm.length; i += 333) {
        ragged.add(pcm.sublist(i, math.min(i + 333, pcm.length)));
      }

      final frames =
          await framePcm16(Stream.fromIterable(ragged), frameSize: 512).toList();

      expect(frames, isNotEmpty);
      expect(frames.every((f) => f.length == 512), isTrue);
    });
  });
}
