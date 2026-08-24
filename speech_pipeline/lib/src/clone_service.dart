import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'audiocpp_ffi.dart';
import 'stt.dart';

/// Voice cloning and recognition behind one API, with the native engines held
/// on a background isolate.
///
/// This is the reusable half of the system: the CLI, the local server and the
/// Flutter app all drive it identically, and none of them touch FFI directly.
/// Synthesis blocks natively for as long as it takes, so it cannot share an
/// isolate with a UI or an HTTP loop.
class CloneService {
  CloneService._(
    this._toWorker,
    this._events,
    this.version,
    this.warmupMs,
    this.sampleRate,
  );

  /// Loads the model and pays the one-off warm-up.
  ///
  /// A Vulkan backend compiles its compute pipelines on first use — tens of
  /// seconds — so a throwaway synthesis happens here rather than inside the
  /// first real request.
  static Future<CloneService> start({
    required String modelPath,
    required String family,
    String? libraryPath,
    AcBackend backend = AcBackend.cpu,
    int device = 0,
    int threads = 8,
    String? sttModelsDir,
    String? sherpaLibraryPath,
    bool warmUp = true,
  }) async {
    final init = ReceivePort();
    await Isolate.spawn(_worker, [
      init.sendPort,
      modelPath,
      family,
      libraryPath,
      backend.index,
      device,
      threads,
      sttModelsDir,
      sherpaLibraryPath,
      warmUp,
    ]);

    final events = StreamController<Map<String, Object?>>.broadcast();
    final ready = Completer<List<Object?>>();
    init.listen((msg) {
      if (msg is List && msg.first is SendPort) {
        ready.complete(msg);
      } else if (msg is Map<String, Object?>) {
        events.add(msg);
      }
    });

    final r = await ready.future;
    if (r.length > 3 && r[3] != null) {
      throw CloneException('engine failed to start: ${r[3]}');
    }
    return CloneService._(
      r[0]! as SendPort,
      events,
      r[1]! as String,
      r[2]! as int,
      r.length > 4 ? r[4]! as int : 0,
    );
  }

  final SendPort _toWorker;
  final StreamController<Map<String, Object?>> _events;

  /// Native shim version, e.g. `audiocpp-c 0.1.0`.
  final String version;

  /// Cost of the first synthesis, which the caller no longer pays.
  final int warmupMs;

  /// Output rate of the loaded voice, measured during warm-up rather than
  /// assumed. Zero when [start] was called with `warmUp: false`, in which case
  /// only [speak] can report it.
  final int sampleRate;

  int _next = 0;

  Future<Map<String, Object?>> _call(Map<String, Object?> msg) async {
    final id = _next++;
    final reply = _events.stream.firstWhere((m) => m['id'] == id);
    _toWorker.send({...msg, 'id': id});
    final m = await reply;
    if (m['error'] != null) throw CloneException(m['error']! as String);
    return m;
  }

  /// Speaks [text], optionally in the voice of [refWavPath].
  ///
  /// OmniVoice conditions on the reference transcript, so passing [refText]
  /// materially improves the clone.
  Future<SynthesisResult> speak(
    String text, {
    String? language,
    String? refWavPath,
    String? refText,
  }) async {
    final started = DateTime.now();
    final m = await _call({
      'op': 'speak',
      'text': text,
      'language': language,
      'refWavPath': refWavPath,
      'refText': refText,
    });
    return SynthesisResult(
      samples: m['samples']! as Float32List,
      sampleRate: m['sampleRate']! as int,
      elapsed: DateTime.now().difference(started),
    );
  }

  /// Recognises [samples]. Nepali and Sanskrit use IndicConformer, English
  /// SenseVoice — see [Stt].
  Future<String> transcribe(
    Float32List samples,
    int sampleRate, {
    String language = 'ne',
  }) async {
    final m = await _call({
      'op': 'stt',
      'samples': samples,
      'sampleRate': sampleRate,
      'language': language,
    });
    return m['text']! as String;
  }

  Future<void> dispose() async {
    _toWorker.send({'op': 'stop'});
    await _events.close();
  }
}

class SynthesisResult {
  SynthesisResult({
    required this.samples,
    required this.sampleRate,
    required this.elapsed,
  });

  final Float32List samples;
  final int sampleRate;
  final Duration elapsed;

  double get seconds => samples.length / sampleRate;

  /// Below 1.0 means faster than real time.
  double get realTimeFactor => elapsed.inMilliseconds / 1000 / seconds;
}

class CloneException implements Exception {
  CloneException(this.message);
  final String message;
  @override
  String toString() => 'CloneException: $message';
}

void _worker(List<Object?> args) {
  final toMain = args[0]! as SendPort;
  final inbox = ReceivePort();
  final sttDir = args[7] as String?;
  final sherpaLib = args[8] as String?;
  final warmUp = args[9]! as bool;

  final AudioCpp engine;
  var warmupMs = 0;
  var sampleRate = 0;
  try {
    engine = AudioCpp.open(
      modelPath: args[1]! as String,
      family: args[2]! as String,
      libraryPath: args[3] as String?,
      backend: AcBackend.values[args[4]! as int],
      device: args[5]! as int,
      threads: args[6]! as int,
    );
    if (warmUp) {
      final t0 = DateTime.now();
      // The throwaway result still carries the voice's real output rate, which
      // callers need before their first synthesis to configure playback.
      sampleRate = engine.synthesize('warm up').sampleRate;
      warmupMs = DateTime.now().difference(t0).inMilliseconds;
    }
  } catch (e) {
    toMain.send([inbox.sendPort, '', 0, '$e', 0]);
    return;
  }

  // Recognisers are per-language and cheap to keep once built.
  final recognisers = <String, Stt>{};
  Stt sttFor(String lang) => recognisers.putIfAbsent(
    lang,
    () => Stt.open(
      modelsDir: sttDir!,
      language: lang,
      nativeLibraryPath: sherpaLib,
    ),
  );

  toMain.send([inbox.sendPort, engine.version, warmupMs, null, sampleRate]);

  inbox.listen((msg) {
    final m = msg as Map<String, Object?>;
    if (m['op'] == 'stop') {
      engine.dispose();
      for (final s in recognisers.values) {
        s.dispose();
      }
      inbox.close();
      return;
    }
    try {
      if (m['op'] == 'stt') {
        if (sttDir == null) throw StateError('no STT models directory given');
        final lang = m['language']! as String;
        final text = sttFor(
          lang == 'npi' ? 'ne' : lang,
        ).transcribe(m['samples']! as Float32List, m['sampleRate']! as int);
        toMain.send({'id': m['id'], 'text': text});
        return;
      }
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
