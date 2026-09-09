import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:speech_pipeline_server/clone_cli.dart';
import 'package:test/test.dart';

/// A PCM16 mono wav: [tone] seconds of a sine, then [silence] seconds of the
/// low-level noise both engines leave behind.
File _wav(Directory dir, {required double tone, required double silence, int rate = 24000}) {
  final n = ((tone + silence) * rate).round();
  final loud = (tone * rate).round();
  final rnd = Random(7);
  final pcm = Int16List(n);
  for (var i = 0; i < n; i++) {
    pcm[i] = i < loud
        ? (sin(i / rate * 2 * pi * 220) * 9000).round()
        : rnd.nextInt(120) - 60;
  }
  final data = pcm.buffer.asUint8List();
  final b = BytesBuilder()
    ..add('RIFF'.codeUnits)
    ..add(_u32(36 + data.length))
    ..add('WAVE'.codeUnits)
    ..add('fmt '.codeUnits)
    ..add(_u32(16))
    ..add(_u16(1))
    ..add(_u16(1))
    ..add(_u32(rate))
    ..add(_u32(rate * 2))
    ..add(_u16(2))
    ..add(_u16(16))
    ..add('data'.codeUnits)
    ..add(_u32(data.length))
    ..add(data);
  final f = File('${dir.path}/probe_${tone}_$silence.wav')
    ..writeAsBytesSync(b.toBytes());
  return f;
}

List<int> _u32(int v) => (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();
List<int> _u16(int v) => (ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List();

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('clone_cli'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('estimateSeconds', () {
    test('grows with the text and never returns a useless floor', () {
      expect(estimateSeconds('Hi.'), greaterThanOrEqualTo(2.0));
      expect(
        estimateSeconds('Eight thousand and one commits in 184 days.'),
        greaterThan(estimateSeconds('Ten apps live.')),
      );
    });

    test('is generous — a truncated line costs more than wasted compute', () {
      // Measured: this line speaks in ~4.3s. The budget must exceed that.
      const line = 'Eight thousand and one commits in a hundred and eighty four days.';
      expect(estimateSeconds(line), greaterThan(4.3));
    });

    test('caps, so one runaway line cannot ask for minutes of audio', () {
      expect(estimateSeconds('x' * 5000), lessThanOrEqualTo(30.0));
    });
  });

  group('trimTrailingSilence', () {
    test('cuts the tail and keeps every loud sample', () {
      final f = _wav(tmp, tone: 2.0, silence: 6.0);
      expect(wavDuration(f), closeTo(8.0, 0.05));
      final after = trimTrailingSilence(f);
      expect(after, greaterThan(2.0));
      expect(after, lessThan(2.6));
      expect(wavDuration(f), closeTo(after, 0.01));
    });

    test('leaves a clip that is already tight alone', () {
      final f = _wav(tmp, tone: 3.0, silence: 0.0);
      expect(trimTrailingSilence(f), closeTo(3.0, 0.05));
    });

    test('does not fail on an all-silent clip', () {
      final f = _wav(tmp, tone: 0.0, silence: 2.0);
      expect(trimTrailingSilence(f), greaterThan(0));
    });
  });

  group('cloneBlocker', () {
    final full = CloneEngines(
      llamaTts: '/bin/true',
      qwenDir: '/tmp',
      omnivoice: '/bin/true',
      omniDir: '/tmp',
    );

    test('passes a configured English request', () {
      expect(cloneBlocker(full, lang: 'en', text: 'hi', refText: ''), isNull);
    });

    test('refuses empty text before touching an engine', () {
      expect(cloneBlocker(full, lang: 'en', text: '   ', refText: ''), isNotNull);
    });

    test('requires the reference transcript for OmniVoice only', () {
      expect(cloneBlocker(full, lang: 'ne', text: 'hi', refText: ''), isNotNull);
      expect(cloneBlocker(full, lang: 'ne', text: 'hi', refText: 'x'), isNull);
    });

    test('names the missing flags when an engine is unconfigured', () {
      final none = CloneEngines();
      expect(cloneBlocker(none, lang: 'en', text: 'hi', refText: ''), contains('--llama-tts'));
      expect(cloneBlocker(none, lang: 'ne', text: 'hi', refText: 'x'), contains('--omnivoice'));
    });
  });

  group('engine arguments', () {
    test('English carries a token budget, because -n defaults to infinity', () {
      final dir = Directory('${tmp.path}/qwen')..createSync();
      File('${dir.path}/Qwen3-TTS-12Hz-1.7B-Base-Q4_K_M.gguf').writeAsStringSync('x');
      File('${dir.path}/mmproj-Qwen3-TTS-12Hz-1.7B-Base-Q8_0.gguf').writeAsStringSync('x');
      final args = CloneEngines(llamaTts: '/bin/true', qwenDir: dir.path)
          .englishArgs('/ref.wav', 'hello there', '/out.wav', maxSeconds: 8);
      expect(args, isNotNull);
      expect(args!.join(' '), contains('-n 96'));
    });

    test('the GGUF match survives a different quantisation in the name', () {
      final dir = Directory('${tmp.path}/qwen2')..createSync();
      File('${dir.path}/Qwen3-TTS-12Hz-1.7B-Base-Q8_0.gguf').writeAsStringSync('x');
      File('${dir.path}/mmproj-Qwen3-TTS-12Hz-1.7B-Base-Q8_0.gguf').writeAsStringSync('x');
      expect(
        CloneEngines(llamaTts: '/bin/true', qwenDir: dir.path)
            .englishArgs('/ref.wav', 'hi', '/out.wav'),
        isNotNull,
      );
    });

    test('OmniVoice maps ne to npi and sa to sa', () {
      final dir = Directory('${tmp.path}/omni')..createSync();
      File('${dir.path}/omnivoice-base-Q8_0.gguf').writeAsStringSync('x');
      File('${dir.path}/omnivoice-tokenizer-Q8_0.gguf').writeAsStringSync('x');
      final e = CloneEngines(omnivoice: '/bin/true', omniDir: dir.path);
      expect(e.indicArgs('ne', '/r.wav', '/r.txt', '/o.wav')!.join(' '), contains('--lang npi'));
      expect(e.indicArgs('sa', '/r.wav', '/r.txt', '/o.wav')!.join(' '), contains('--lang sa'));
    });

    test('missing models are reported as null rather than a bad command', () {
      expect(
        CloneEngines(llamaTts: '/bin/true', qwenDir: '${tmp.path}/nothing')
            .englishArgs('/ref.wav', 'hi', '/out.wav'),
        isNull,
      );
    });
  });
}
