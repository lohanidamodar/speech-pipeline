import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'engines.dart';
import 'sherpa_init.dart';

enum TtsModelKind { kokoro, vits, matcha }

/// Sendable synthesiser description; the worker builds the native engine.
class TtsConfig {
  const TtsConfig.kokoro({
    required this.model,
    required this.voices,
    required this.tokens,
    required this.dataDir,
    this.lexicon = '',
    this.speakerId = 0,
    this.speed = 1.0,
    this.numThreads = 2,
    this.nativeLibraryPath,
  }) : kind = TtsModelKind.kokoro,
       acousticModel = '',
       vocoder = '';

  const TtsConfig.vits({
    required this.model,
    required this.tokens,
    this.dataDir = '',
    this.lexicon = '',
    this.speakerId = 0,
    this.speed = 1.0,
    this.numThreads = 2,
    this.nativeLibraryPath,
  }) : kind = TtsModelKind.vits,
       voices = '',
       acousticModel = '',
       vocoder = '';

  const TtsConfig.matcha({
    required this.acousticModel,
    required this.vocoder,
    required this.tokens,
    this.dataDir = '',
    this.lexicon = '',
    this.speakerId = 0,
    this.speed = 1.0,
    this.numThreads = 2,
    this.nativeLibraryPath,
  }) : kind = TtsModelKind.matcha,
       model = '',
       voices = '';

  final TtsModelKind kind;
  final String model;
  final String voices;
  final String acousticModel;
  final String vocoder;
  final String tokens;
  final String dataDir;
  final String lexicon;
  final int speakerId;
  final double speed;
  final int numThreads;
  final String? nativeLibraryPath;
}

/// TTS running on a dedicated long-lived isolate, streaming audio as it is
/// generated and cancellable mid-utterance.
///
/// Cancellation goes through a shared native flag rather than a message,
/// because during synthesis the worker is blocked inside a native call and
/// cannot pump its event loop — a `cancel` message would not be seen until the
/// utterance it was meant to interrupt had already finished.
class SherpaTtsEngine implements TtsEngine {
  SherpaTtsEngine._(
    this._isolate,
    this._fromWorker,
    this._toWorker,
    this._events,
    this._cancelFlag,
    this.sampleRate,
  );

  static Future<SherpaTtsEngine> spawn(TtsConfig config) async {
    final cancelFlag = calloc<Int32>();
    final fromWorker = ReceivePort();
    final isolate = await Isolate.spawn(_workerMain, (
      fromWorker.sendPort,
      config,
      cancelFlag.address,
    ), debugName: 'tts');

    final events = StreamController<(int, Object?)>.broadcast();
    final ready = Completer<(SendPort, int)>();

    fromWorker.listen((msg) {
      switch (msg) {
        case (SendPort p, int rate):
          ready.complete((p, rate));
        case (int id, Object? payload):
          events.add((id, payload));
      }
    });

    final (toWorker, rate) = await ready.future;
    return SherpaTtsEngine._(
      isolate,
      fromWorker,
      toWorker,
      events,
      cancelFlag,
      rate,
    );
  }

  final Isolate _isolate;

  /// Held so [dispose] can close it — an open ReceivePort keeps the VM's event
  /// loop alive, so leaving it open stops the process from ever exiting.
  final ReceivePort _fromWorker;

  final SendPort _toWorker;
  final StreamController<(int, Object?)> _events;
  final Pointer<Int32> _cancelFlag;

  @override
  final int sampleRate;

  int _nextId = 0;

  @override
  Stream<AudioChunk> synthesize(String text) {
    final id = _nextId++;
    final out = StreamController<AudioChunk>();
    late StreamSubscription<(int, Object?)> sub;

    out.onListen = () {
      _cancelFlag.value = 0;
      sub = _events.stream.where((e) => e.$1 == id).listen((e) {
        switch (e.$2) {
          case AudioChunk chunk:
            out.add(chunk);
          case null:
            sub.cancel();
            out.close();
        }
      });
      _toWorker.send((id, text));
    };

    // Barge-in: the consumer walking away stops generation at the next chunk.
    out.onCancel = () async {
      _cancelFlag.value = 1;
      await sub.cancel();
    };

    return out.stream;
  }

  @override
  Future<void> dispose() async {
    _cancelFlag.value = 1;
    await _events.close();
    _isolate.kill(priority: Isolate.immediate);
    _fromWorker.close();
    calloc.free(_cancelFlag);
  }

  static void _workerMain((SendPort, TtsConfig, int) args) {
    final (toMain, config, cancelAddress) = args;
    final cancelFlag = Pointer<Int32>.fromAddress(cancelAddress);

    initSherpaBindings(config.nativeLibraryPath);
    final tts = sherpa.OfflineTts(_buildConfig(config));

    final inbox = ReceivePort();
    toMain.send((inbox.sendPort, tts.sampleRate));

    inbox.listen((msg) {
      final (id, text) = msg as (int, String);
      tts.generateWithCallback(
        text: text,
        sid: config.speakerId,
        speed: config.speed,
        // sherpa continues while the callback returns 1, stops on 0.
        callback: (samples) {
          if (cancelFlag.value != 0) return 0;
          toMain.send((id, AudioChunk.fromList(samples)));
          return 1;
        },
      );
      toMain.send((id, null)); // end of utterance
    });
  }

  static sherpa.OfflineTtsConfig _buildConfig(TtsConfig c) {
    final model = switch (c.kind) {
      TtsModelKind.kokoro => sherpa.OfflineTtsModelConfig(
        kokoro: sherpa.OfflineTtsKokoroModelConfig(
          model: c.model,
          voices: c.voices,
          tokens: c.tokens,
          dataDir: c.dataDir,
          lexicon: c.lexicon,
        ),
        numThreads: c.numThreads,
        debug: false,
      ),
      TtsModelKind.vits => sherpa.OfflineTtsModelConfig(
        vits: sherpa.OfflineTtsVitsModelConfig(
          model: c.model,
          tokens: c.tokens,
          dataDir: c.dataDir,
          lexicon: c.lexicon,
        ),
        numThreads: c.numThreads,
        debug: false,
      ),
      TtsModelKind.matcha => sherpa.OfflineTtsModelConfig(
        matcha: sherpa.OfflineTtsMatchaModelConfig(
          acousticModel: c.acousticModel,
          vocoder: c.vocoder,
          tokens: c.tokens,
          dataDir: c.dataDir,
          lexicon: c.lexicon,
        ),
        numThreads: c.numThreads,
        debug: false,
      ),
    };
    return sherpa.OfflineTtsConfig(model: model);
  }
}
