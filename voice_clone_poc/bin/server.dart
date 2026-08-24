import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;

import '../lib/audiocpp_ffi.dart';
import '../lib/stt.dart';

/// Voice cloning over dart:ffi — record in the browser, clone, play back.
///
/// The model is loaded once and stays resident. That is the point of the FFI
/// route: a subprocess pays weight load *and* Vulkan pipeline compilation on
/// every utterance, which together dominated everything else we measured.
Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('model', mandatory: true)
    ..addOption('family', defaultsTo: 'omnivoice')
    ..addOption('lib', help: 'Directory holding libaudiocpp_c.* / .dll')
    ..addOption('backend', defaultsTo: 'cpu',
        allowed: ['cpu', 'cuda', 'vulkan', 'metal', 'hip', 'best'])
    ..addOption('device', defaultsTo: '0')
    ..addOption('threads', defaultsTo: '8')
    ..addOption('port', defaultsTo: '8080')
    ..addOption('web', defaultsTo: 'web')
    ..addOption('host', defaultsTo: '127.0.0.1',
        help: 'Use 0.0.0.0 to reach it from a phone on the same network.')
    ..addOption('cert', help: 'TLS certificate (PEM).')
    ..addOption('key', help: 'TLS private key (PEM).')
    ..addOption('models-dir', help: 'Directory of STT models.')
    ..addOption('sherpa-lib', help: 'Directory holding the sherpa-onnx library.');

  final args = parser.parse(argv);
  final webRoot = Directory(args.option('web')!);
  if (!webRoot.existsSync()) {
    stderr.writeln('No web root at ${webRoot.path}');
    exitCode = 1;
    return;
  }

  // Synthesis blocks for as long as it takes; on its own isolate the HTTP
  // server stays responsive and requests queue instead of piling up on the
  // event loop.
  final engine = await _EngineHost.spawn(
    modelPath: args.option('model')!,
    family: args.option('family')!,
    libraryPath: args.option('lib'),
    backend: AcBackend.values.byName(args.option('backend')!),
    device: int.parse(args.option('device')!),
    threads: int.parse(args.option('threads')!),
  );

  final work = Directory.systemTemp.createTempSync('voiceclone');

  // Recognisers are per-language and cheap to hold, so they are opened on
  // first use and kept.
  final modelsDir = args.option('models-dir');
  final sherpaLib = args.option('sherpa-lib');
  final recognisers = <String, Stt>{};
  Stt? sttFor(String lang) {
    if (modelsDir == null) return null;
    return recognisers.putIfAbsent(
      lang,
      () => Stt.open(
          modelsDir: modelsDir, language: lang, nativeLibraryPath: sherpaLib),
    );
  }

  Future<Response> handler(Request req) async {
    if (req.method == 'POST' && req.url.path == 'api/clone') {
      return _clone(req, engine, work);
    }
    if (req.method == 'POST' && req.url.path == 'api/transcribe') {
      return _transcribe(req, sttFor);
    }
    if (req.method == 'GET' && req.url.path == 'api/status') {
      return Response.ok(
        '{"ready":${engine.ready},"backend":"${args.option('backend')}",'
        '"warmupMs":${engine.warmupMs},"version":"${engine.version}",'
        '"stt":${modelsDir != null}}',
        headers: {'content-type': 'application/json'},
      );
    }
    if (req.method != 'GET') return Response.notFound('');

    final name = req.url.path.isEmpty ? 'index.html' : req.url.path;
    final file = File('${webRoot.path}/$name');
    if (!file.existsSync()) return Response.notFound('not found');
    return Response.ok(file.readAsBytesSync(), headers: {
      'content-type': name.endsWith('.html')
          ? 'text/html; charset=utf-8'
          : 'application/octet-stream',
    });
  }

  // Phones refuse getUserMedia outside a secure context, so serving over the
  // LAN needs TLS even though localhost would not.
  SecurityContext? tls;
  final cert = args.option('cert'), key = args.option('key');
  if (cert != null && key != null) {
    tls = SecurityContext()
      ..useCertificateChain(cert)
      ..usePrivateKey(key);
  }

  final host = args.option('host')!;
  final address =
      host == '0.0.0.0' ? InternetAddress.anyIPv4 : InternetAddress(host);
  final port = int.parse(args.option('port')!);
  final pipeline = const Pipeline().addHandler(handler);

  final server = tls == null
      ? await io.serve(pipeline, address, port)
      : await io.serve(pipeline, address, port, securityContext: tls);

  final scheme = tls == null ? 'http' : 'https';
  stdout.writeln('\n  Voice cloning POC  →  $scheme://localhost:${server.port}');
  if (host == '0.0.0.0') {
    for (final ni in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final a in ni.addresses) {
        if (!a.isLoopback) {
          stdout.writeln('  on this network      →  $scheme://${a.address}:${server.port}');
        }
      }
    }
    if (tls == null) {
      stdout.writeln('  ! microphone will be blocked over plain http — pass --cert/--key');
    }
  }
  stdout.writeln('  engine ${engine.version}  backend=${args.option('backend')}'
      '  warmup ${engine.warmupMs}ms\n');
}

Future<Response> _clone(
    Request req, _EngineHost engine, Directory work) async {
  final text = Uri.decodeComponent(req.headers['x-text'] ?? '').trim();
  final refText = Uri.decodeComponent(req.headers['x-ref-text'] ?? '').trim();
  final lang = req.headers['x-lang'];
  if (text.isEmpty) return Response.badRequest(body: 'No text supplied.');

  final bytes = await req.read().expand((c) => c).toList();
  String? refPath;
  if (bytes.length > 1000) {
    refPath = '${work.path}/ref_${DateTime.now().microsecondsSinceEpoch}.wav';
    File(refPath).writeAsBytesSync(bytes);
  }

  final started = DateTime.now();
  try {
    final result = await engine.synthesize(
      text: text,
      language: lang,
      refWavPath: refPath,
      refText: refText.isEmpty ? null : refText,
    );
    final ms = DateTime.now().difference(started).inMilliseconds;
    final secs = result.samples.length / result.sampleRate;
    stdout.writeln('[clone] ${secs.toStringAsFixed(2)}s audio in ${ms}ms  '
        'RTF ${(ms / 1000 / secs).toStringAsFixed(3)}'
        '${refPath == null ? "" : "  (cloned)"}');

    return Response.ok(_wav(result.samples, result.sampleRate), headers: {
      'content-type': 'audio/wav',
      'x-elapsed-ms': '$ms',
      'x-audio-seconds': secs.toStringAsFixed(2),
      'x-rtf': (ms / 1000 / secs).toStringAsFixed(3),
    });
  } catch (e) {
    stdout.writeln('[clone] failed: $e');
    return Response.internalServerError(body: '$e');
  } finally {
    if (refPath != null) File(refPath).deleteSync();
  }
}

/// Transcribes the uploaded WAV so the reference transcript fills itself in.
Future<Response> _transcribe(Request req, Stt? Function(String) sttFor) async {
  final lang = req.headers['x-lang'] ?? 'ne';
  final bytes = await req.read().expand((c) => c).toList();
  if (bytes.length < 1000) {
    return Response.badRequest(body: 'Recording too short.');
  }
  final Stt? stt;
  try {
    stt = sttFor(lang == 'npi' ? 'ne' : lang);
  } on StateError catch (e) {
    return Response.internalServerError(body: e.message);
  }
  if (stt == null) {
    return Response.internalServerError(body: 'STT not configured (--models-dir).');
  }

  final wav = Uint8List.fromList(bytes);
  final (samples, rate) = _decodeWav(wav);
  if (samples.isEmpty) {
    return Response.badRequest(body: 'Could not read the recording as WAV.');
  }

  final started = DateTime.now();
  final text = stt.transcribe(samples, rate);
  final ms = DateTime.now().difference(started).inMilliseconds;
  stdout.writeln('[stt] $lang ${ms}ms: "$text"');
  return Response.ok(text, headers: {
    'content-type': 'text/plain; charset=utf-8',
    'x-elapsed-ms': '\$ms',
  });
}

/// Minimal 16-bit PCM WAV reader — enough for what the browser uploads.
(Float32List, int) _decodeWav(Uint8List bytes) {
  if (bytes.length < 44) return (Float32List(0), 0);
  final d = ByteData.sublistView(bytes);
  final rate = d.getUint32(24, Endian.little);
  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final size = d.getUint32(offset + 4, Endian.little);
    if (id == 'data') {
      final n = (size ~/ 2).clamp(0, (bytes.length - offset - 8) ~/ 2);
      final out = Float32List(n);
      for (var i = 0; i < n; i++) {
        out[i] = d.getInt16(offset + 8 + i * 2, Endian.little) / 32768.0;
      }
      return (out, rate);
    }
    offset += 8 + size + (size.isOdd ? 1 : 0);
  }
  return (Float32List(0), rate);
}

Uint8List _wav(Float32List samples, int rate) {
  final d = ByteData(44 + samples.length * 2);
  void tag(int o, String s) {
    for (var i = 0; i < s.length; i++) d.setUint8(o + i, s.codeUnitAt(i));
  }

  final n = samples.length * 2;
  tag(0, 'RIFF');
  d.setUint32(4, 36 + n, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  d.setUint32(16, 16, Endian.little);
  d.setUint16(20, 1, Endian.little);
  d.setUint16(22, 1, Endian.little);
  d.setUint32(24, rate, Endian.little);
  d.setUint32(28, rate * 2, Endian.little);
  d.setUint16(32, 2, Endian.little);
  d.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  d.setUint32(40, n, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    d.setInt16(44 + i * 2, (samples[i].clamp(-1.0, 1.0) * 32767).round(),
        Endian.little);
  }
  return d.buffer.asUint8List();
}

/// Owns the native engine on a dedicated isolate.
class _EngineHost {
  _EngineHost._(this._toWorker, this._replies, this.version, this.warmupMs);

  static Future<_EngineHost> spawn({
    required String modelPath,
    required String family,
    String? libraryPath,
    required AcBackend backend,
    required int device,
    required int threads,
  }) async {
    final init = ReceivePort();
    await Isolate.spawn(_worker, [
      init.sendPort, modelPath, family, libraryPath, backend.index, device,
      threads,
    ]);

    final replies = StreamController<Map<String, Object?>>.broadcast();
    final ready = Completer<List<Object?>>();
    init.listen((msg) {
      if (msg is List && msg.first is SendPort) {
        ready.complete(msg);
      } else if (msg is Map<String, Object?>) {
        replies.add(msg);
      }
    });

    final r = await ready.future;
    if (r.length > 3 && r[3] != null) {
      throw StateError('engine failed to load: ${r[3]}');
    }
    return _EngineHost._(
        r[0]! as SendPort, replies, r[1]! as String, r[2]! as int);
  }

  final SendPort _toWorker;
  final StreamController<Map<String, Object?>> _replies;
  final String version;
  final int warmupMs;
  bool get ready => true;
  int _next = 0;

  Future<({Float32List samples, int sampleRate})> synthesize({
    required String text,
    String? language,
    String? refWavPath,
    String? refText,
  }) async {
    final id = _next++;
    final reply = _replies.stream.firstWhere((m) => m['id'] == id);
    _toWorker.send({
      'id': id,
      'text': text,
      'language': language,
      'refWavPath': refWavPath,
      'refText': refText,
    });
    final m = await reply;
    if (m['error'] != null) throw StateError(m['error']! as String);
    return (
      samples: m['samples']! as Float32List,
      sampleRate: m['sampleRate']! as int,
    );
  }
}

void _worker(List<Object?> args) {
  final toMain = args[0]! as SendPort;
  final inbox = ReceivePort();

  final AudioCpp engine;
  final int warmupMs;
  try {
    engine = AudioCpp.open(
      modelPath: args[1]! as String,
      family: args[2]! as String,
      libraryPath: args[3] as String?,
      backend: AcBackend.values[args[4]! as int],
      device: args[5]! as int,
      threads: args[6]! as int,
    );
    // Vulkan compiles its compute pipelines on first use — tens of seconds.
    // Paying it here means the first user request is fast, not the outlier.
    final t0 = DateTime.now();
    engine.synthesize('warm up');
    warmupMs = DateTime.now().difference(t0).inMilliseconds;
  } catch (e) {
    toMain.send([inbox.sendPort, '', 0, '$e']);
    return;
  }

  toMain.send([inbox.sendPort, engine.version, warmupMs, null]);

  inbox.listen((msg) {
    final m = msg as Map<String, Object?>;
    try {
      final audio = engine.synthesize(
        m['text']! as String,
        language: m['language'] as String?,
        refWavPath: m['refWavPath'] as String?,
        refText: m['refText'] as String?,
      );
      toMain.send({
        'id': m['id'],
        'samples': audio.samples,
        'sampleRate': audio.sampleRate,
      });
    } catch (e) {
      toMain.send({'id': m['id'], 'error': '$e'});
    }
  });
}
