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

      expect(
        energyAt(out, 6000, 16000),
        lessThan(0.02),
        reason: 'aliased image should be suppressed',
      );
    });

    test(
      'linear interpolation would have aliased — proving the filter works',
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

        expect(
          energyAt(naive, 6000, 16000),
          greaterThan(0.2),
          reason: 'the naive path really does fold 10 kHz down to 6 kHz',
        );
      },
    );

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

      final frames = await framePcm16(
        Stream.fromIterable(ragged),
        frameSize: 512,
      ).toList();

      expect(frames, isNotEmpty);
      expect(frames.every((f) => f.length == 512), isTrue);
    });
  });

  _realTime();

  group('decodeWav', () {
    Uint8List riff(List<(String, Uint8List)> chunks) {
      final body = BytesBuilder();
      for (final (id, data) in chunks) {
        body.add(id.codeUnits);
        final size = ByteData(4)..setUint32(0, data.length, Endian.little);
        body
          ..add(size.buffer.asUint8List())
          ..add(data);
        if (data.length.isOdd) body.addByte(0);
      }
      final payload = body.takeBytes();
      final out = BytesBuilder()..add('RIFF'.codeUnits);
      final riffSize = ByteData(4)
        ..setUint32(0, 4 + payload.length, Endian.little);
      out
        ..add(riffSize.buffer.asUint8List())
        ..add('WAVE'.codeUnits)
        ..add(payload);
      return out.takeBytes();
    }

    Uint8List fmt({int channels = 1, int rate = 16000, int bits = 16}) {
      final d = ByteData(16);
      d.setUint16(0, 1, Endian.little);
      d.setUint16(2, channels, Endian.little);
      d.setUint32(4, rate, Endian.little);
      d.setUint32(8, rate * channels * bits ~/ 8, Endian.little);
      d.setUint16(12, channels * bits ~/ 8, Endian.little);
      d.setUint16(14, bits, Endian.little);
      return d.buffer.asUint8List();
    }

    Uint8List pcm(List<int> values) {
      final d = ByteData(values.length * 2);
      for (var i = 0; i < values.length; i++) {
        d.setInt16(i * 2, values[i], Endian.little);
      }
      return d.buffer.asUint8List();
    }

    test('reads a plain fmt-then-data file', () {
      final (s, rate) = decodeWav(
        riff([
          ('fmt ', fmt(rate: 24000)),
          ('data', pcm([0, 16384, -16384])),
        ]),
      );
      expect(rate, 24000);
      expect(s.length, 3);
      expect(s[1], closeTo(0.5, 0.001));
    });

    test('finds fmt after a leading LIST chunk', () {
      // The regression: reading the rate from a fixed offset returned 0 here,
      // which reached the recogniser as "resample from 0 Hz" and crashed it.
      final (s, rate) = decodeWav(
        riff([
          ('LIST', Uint8List.fromList('INFOsomething'.codeUnits)),
          ('fmt ', fmt(rate: 22050)),
          ('data', pcm([0, 8192])),
        ]),
      );
      expect(rate, 22050, reason: 'fmt must be located, not assumed');
      expect(s.length, 2);
    });

    test('downmixes stereo to mono', () {
      final (s, rate) = decodeWav(
        riff([
          ('fmt ', fmt(channels: 2, rate: 16000)),
          ('data', pcm([16384, -16384, 8192, 8192])),
        ]),
      );
      expect(rate, 16000);
      expect(s.length, 2, reason: 'two frames, not four samples');
      expect(s[0], closeTo(0.0, 0.001));
      expect(s[1], closeTo(0.25, 0.001));
    });

    test('tolerates a data size larger than the file', () {
      final good = riff([
        ('fmt ', fmt()),
        ('data', pcm([1, 2, 3, 4])),
      ]);
      final truncated = Uint8List.sublistView(good, 0, good.length - 4);
      final (s, rate) = decodeWav(truncated);
      expect(rate, 16000);
      expect(s.length, 2, reason: 'reads what is actually present');
    });

    test('rejects non-16-bit audio rather than misreading it', () {
      final (s, _) = decodeWav(
        riff([
          ('fmt ', fmt(bits: 32)),
          ('data', pcm([1, 2, 3, 4])),
        ]),
      );
      expect(s, isEmpty);
    });

    test('round-trips what encodeWav produces', () {
      final original = tone(440, 22050, 0.05);
      final (s, rate) = decodeWav(encodeWav(original, 22050));
      expect(rate, 22050);
      expect(s.length, original.length);
      for (var i = 0; i < s.length; i++) {
        expect(s[i], closeTo(original[i], 2 / 32767));
      }
    });
  });
}

void _realTime() {
  group('atRealTime', () {
    test('holds a burst back to roughly the speed of speech', () async {
      // 0.5s of audio delivered instantly should still take ~0.5s to arrive.
      final chunks = [for (var i = 0; i < 10; i++) Float32List(800)];
      final clock = Stopwatch()..start();
      final out = await atRealTime(Stream.fromIterable(chunks)).toList();

      expect(out.length, 10);
      expect(
        clock.elapsed.inMilliseconds,
        greaterThan(400),
        reason: '8000 samples at 16 kHz is half a second of speech',
      );
    });

    test('does not delay audio that already arrives slowly', () async {
      // A real microphone is already paced; pacing it again would add latency
      // to every turn.
      Stream<Float32List> slow() async* {
        for (var i = 0; i < 3; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 40));
          yield Float32List(160); // 10ms of audio, arriving every 40ms
        }
      }

      final clock = Stopwatch()..start();
      await atRealTime(slow()).drain<void>();
      expect(clock.elapsed.inMilliseconds, lessThan(200));
    });

    test('passes an empty stream straight through', () async {
      expect(
        await atRealTime(const Stream<Float32List>.empty()).toList(),
        isEmpty,
      );
    });
  });
}
