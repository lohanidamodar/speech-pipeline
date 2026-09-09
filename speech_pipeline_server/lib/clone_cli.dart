import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Locates each engine's GGUFs and builds its command line.
///
/// Shared by `clone_server.dart` and `clone_say.dart` so the two cannot drift
/// on which flags an engine takes.
class CloneEngines {
  CloneEngines({
    this.llamaTts,
    this.qwenDir,
    this.omnivoice,
    this.omniDir,
    this.steps = '16',
  });

  final String? llamaTts, qwenDir, omnivoice, omniDir;
  final String steps;

  bool get hasEnglish => llamaTts != null && qwenDir != null;
  bool get hasIndic => omnivoice != null && omniDir != null;

  String describe() => [
    '  English  (Qwen3-TTS): ${hasEnglish ? "ready" : "not configured"}',
    '  ne / sa (OmniVoice) : ${hasIndic ? "ready" : "not configured"}',
  ].join('\n');

  /// GGUF filenames carry their quantisation, so they are matched rather than
  /// hardcoded — a different download would otherwise break this.
  String? _find(String? dir, RegExp pattern) {
    if (dir == null) return null;
    final d = Directory(dir);
    if (!d.existsSync()) return null;
    for (final f in d.listSync().whereType<File>()) {
      if (pattern.hasMatch(f.path.split(Platform.pathSeparator).last)) {
        return f.path;
      }
    }
    return null;
  }

  /// Qwen3-TTS emits 12 audio tokens per second, so a token budget is a
  /// duration budget. Without one `-n` defaults to infinity and the model
  /// rambles: a four-second line measured 40.96s, 90% of it junk, and took
  /// 408s to generate against 46s when capped.
  List<String>? englishArgs(
    String ref,
    String text,
    String out, {
    double? maxSeconds,
  }) {
    final model = _find(qwenDir, RegExp(r'^Qwen3-TTS.*\.gguf$'));
    final mmproj = _find(qwenDir, RegExp(r'^mmproj-.*\.gguf$'));
    if (model == null || mmproj == null) return null;
    final budget = maxSeconds ?? estimateSeconds(text);
    return [
      '-m', model,
      '--mmproj', mmproj,
      '--tts-lang', 'en',
      '--tts-speaker-file', ref,
      '-p', text,
      '-n', '${(budget * 12).round()}',
      '-o', out,
    ];
  }

  /// The target text goes to stdin, not argv — see [runClone].
  List<String>? indicArgs(
    String lang,
    String ref,
    String refTextPath,
    String out, {
    double? maxSeconds,
  }) {
    final model = _find(omniDir, RegExp(r'^omnivoice-base.*\.gguf$'));
    final codec = _find(omniDir, RegExp(r'^omnivoice-tokenizer.*\.gguf$'));
    if (model == null || codec == null) return null;
    return [
      '--model', model,
      '--codec', codec,
      '--lang', lang == 'ne' ? 'npi' : 'sa',
      '--ref-wav', ref,
      '--ref-text', refTextPath,
      '--steps', steps,
      if (maxSeconds != null) ...['--duration', maxSeconds.toStringAsFixed(1)],
      '-o', out,
    ];
  }
}

/// A generous speaking-time estimate for [text].
///
/// Deliberately generous: overrunning wastes a little compute, while
/// underrunning truncates the line mid-word.
double estimateSeconds(String text) {
  final chars = text.trim().length;
  return (chars / 13.0 + 1.5).clamp(2.0, 30.0);
}

/// Why a synthesis request cannot be served, or null if it can.
String? cloneBlocker(
  CloneEngines engines, {
  required String lang,
  required String text,
  required String refText,
}) {
  if (text.trim().isEmpty) return 'No text supplied.';
  if (lang == 'en') {
    if (!engines.hasEnglish) {
      return 'English engine not configured (--llama-tts / --qwen-dir).';
    }
    return null;
  }
  if (!engines.hasIndic) {
    return 'OmniVoice not configured (--omnivoice / --omni-dir).';
  }
  if (refText.trim().isEmpty) {
    return 'OmniVoice needs the transcript of the reference recording.';
  }
  return null;
}

/// Runs one engine and returns its stderr+stdout on failure, null on success.
///
/// OmniVoice reads its target text from stdin; llama-tts takes it in argv.
/// Both are driven through [Process.start] so the stdin case is not a special
/// path that only one caller remembers to use.
Future<String?> runClone({
  required String exe,
  required List<String> args,
  required File out,
  String? stdinText,
}) async {
  if (out.existsSync()) out.deleteSync();
  final Process proc;
  try {
    proc = await Process.start(exe, args);
  } on ProcessException catch (e) {
    return 'Cannot run $exe: ${e.message}';
  }
  if (stdinText != null) proc.stdin.write(stdinText);
  await proc.stdin.close();

  final err = StringBuffer();
  final drain = [
    proc.stdout.transform(utf8.decoder).forEach(err.write),
    proc.stderr.transform(utf8.decoder).forEach(err.write),
  ];
  await proc.exitCode;
  await Future.wait(drain);

  if (!out.existsSync() || out.lengthSync() < 100) {
    final why = err.toString().trim();
    return why.isEmpty ? 'Engine produced no audio.' : why;
  }
  return null;
}

/// Duration of a PCM16 wav in seconds, or 0 if it cannot be read.
double wavDuration(File wav) => _durationOf(wav.readAsBytesSync()) ?? 0;

/// Trims the trailing near-silence a generator leaves after the last word.
///
/// Returns the new duration in seconds. PCM16 mono only, which is what both
/// engines emit; anything else is left untouched.
double trimTrailingSilence(File wav, {double keepTail = 0.25}) {
  final bytes = wav.readAsBytesSync();
  final dataAt = _findDataChunk(bytes);
  if (dataAt == null) return _durationOf(bytes) ?? 0;

  final (offset, length) = dataAt;
  final view = ByteData.sublistView(bytes, offset, offset + length);
  final samples = length ~/ 2;
  if (samples == 0) return 0;

  final rate = _sampleRateOf(bytes) ?? 24000;
  final window = (rate * 0.025).round().clamp(1, samples);
  var peak = 0;
  for (var i = 0; i < samples; i++) {
    final v = view.getInt16(i * 2, Endian.little).abs();
    if (v > peak) peak = v;
  }
  if (peak == 0) return samples / rate;

  final floor = peak * 0.02;
  var lastLoud = 0;
  for (var start = 0; start < samples; start += window) {
    final end = (start + window).clamp(0, samples);
    var w = 0;
    for (var i = start; i < end; i++) {
      final v = view.getInt16(i * 2, Endian.little).abs();
      if (v > w) w = v;
    }
    if (w > floor) lastLoud = end;
  }

  final keep = (lastLoud + rate * keepTail).round().clamp(1, samples);
  if (keep >= samples) return samples / rate;

  final trimmed = Uint8List(offset + keep * 2)
    ..setRange(0, offset, bytes)
    ..setRange(offset, offset + keep * 2, bytes, offset);
  _patchSizes(trimmed, offset, keep * 2);
  wav.writeAsBytesSync(trimmed);
  return keep / rate;
}

(int, int)? _findDataChunk(Uint8List b) {
  if (b.length < 44 || String.fromCharCodes(b.sublist(0, 4)) != 'RIFF') {
    return null;
  }
  var i = 12;
  while (i + 8 <= b.length) {
    final id = String.fromCharCodes(b.sublist(i, i + 4));
    final size = ByteData.sublistView(b, i + 4, i + 8).getUint32(0, Endian.little);
    if (id == 'data') return (i + 8, size.clamp(0, b.length - i - 8));
    i += 8 + size + (size.isOdd ? 1 : 0);
  }
  return null;
}

int? _sampleRateOf(Uint8List b) {
  var i = 12;
  while (i + 8 <= b.length) {
    final id = String.fromCharCodes(b.sublist(i, i + 4));
    final size = ByteData.sublistView(b, i + 4, i + 8).getUint32(0, Endian.little);
    if (id == 'fmt ' && i + 16 <= b.length) {
      return ByteData.sublistView(b, i + 12, i + 16).getUint32(0, Endian.little);
    }
    i += 8 + size + (size.isOdd ? 1 : 0);
  }
  return null;
}

double? _durationOf(Uint8List b) {
  final d = _findDataChunk(b);
  final r = _sampleRateOf(b);
  if (d == null || r == null || r == 0) return null;
  return d.$2 / 2 / r;
}

void _patchSizes(Uint8List b, int dataOffset, int dataBytes) {
  final v = ByteData.sublistView(b);
  v.setUint32(4, b.length - 8, Endian.little);
  v.setUint32(dataOffset - 4, dataBytes, Endian.little);
}
