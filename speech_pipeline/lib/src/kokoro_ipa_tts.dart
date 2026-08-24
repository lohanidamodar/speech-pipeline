import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dart_onnx/dart_onnx.dart';
import 'package:ffi/ffi.dart';

import 'engines.dart';

/// Kokoro driven straight from IPA, bypassing sherpa-onnx's text front-end.
///
/// sherpa's Kokoro path is text → espeak-ng/lexicon → IPA, with no way to
/// supply phonemes yourself. For Sanskrit that front-end is the problem: the
/// only Devanagari voice espeak offers is Hindi, which deletes the inherent
/// schwa and mangles anusvara and visarga. Since Kokoro's own vocabulary is
/// already IPA — and already contains every retroflex and aspirate Sanskrit
/// needs — the fix is to phonemise in Dart and feed the model directly.
///
/// The model is the same `kokoro-en-v0_19` bundle the English path uses.
///
/// Requires ONNX Runtime. Set `DART_ONNX_LIB_PATH` to the full path of
/// `libonnxruntime.so` (`.dylib`/`.dll`), or put it on the loader path —
/// `tool/fetch_models.sh` already places one in `native/`.
class KokoroIpaConfig {
  const KokoroIpaConfig({
    required this.model,
    required this.voices,
    required this.tokens,
    this.voiceIndex = 0,
    this.speed = 1.0,
    this.voiceCount = 11,
    this.nativeLibraryPath,
  });

  final String model;
  final String voices;
  final String tokens;

  /// Directory holding `libonnxruntime.*`, same one sherpa uses.
  ///
  /// Given this, the library is loaded by absolute path before dart_onnx looks
  /// for it, so no environment variable is involved. Null falls back to
  /// `DART_ONNX_LIB_PATH` or the system loader path.
  final String? nativeLibraryPath;

  /// Index into the bundle's voice list — [kokoroV019Voices] for the English
  /// bundle, [kokoroMultiLangVoices] for multi-lang.
  final int voiceIndex;

  /// How many voices `voices.bin` holds: 11 for kokoro-en-v0_19, 53 for
  /// kokoro-multi-lang-v1_0. Needed to work out the style-table geometry.
  final int voiceCount;

  final double speed;
}

/// Voice order inside `kokoro-multi-lang-v1_0/voices.bin` (53 speakers).
///
/// `hf_`/`hm_` are Hindi. sherpa's docs say this bundle "supports English and
/// Chinese", but that describes its *text* front-end — the voice pack is the
/// full upstream set. Feeding IPA directly bypasses the front-end, so any of
/// these is usable.
const kokoroMultiLangVoices = [
  'af_alloy', 'af_aoede', 'af_bella', 'af_heart', 'af_jessica', 'af_kore',
  'af_nicole', 'af_nova', 'af_river', 'af_sarah', 'af_sky', 'am_adam',
  'am_echo', 'am_eric', 'am_fenrir', 'am_liam', 'am_michael', 'am_onyx',
  'am_puck', 'am_santa', 'bf_alice', 'bf_emma', 'bf_isabella', 'bf_lily',
  'bm_daniel', 'bm_fable', 'bm_george', 'bm_lewis', 'ef_dora', 'em_alex',
  'ff_siwis', 'hf_alpha', 'hf_beta', 'hm_omega', 'hm_psi', 'if_sara',
  'im_nicola', 'jf_alpha', 'jf_gongitsune', 'jf_nezumi', 'jf_tebukuro',
  'jm_kumo', 'pf_dora', 'pm_alex', 'pm_santa', 'zf_xiaobei', 'zf_xiaoni',
  'zf_xiaoxiao', 'zf_xiaoyi', 'zm_yunjian', 'zm_yunxi', 'zm_yunxia',
  'zm_yunyang',
];

/// The Hindi voices, which are the closest match for Devanagari.
const kokoroHindiFemale = 31; // hf_alpha
const kokoroHindiMale = 33; // hm_omega

/// Voice order inside `kokoro-en-v0_19/voices.bin`.
const kokoroV019Voices = [
  'af',
  'af_bella',
  'af_nicole',
  'af_sarah',
  'af_sky',
  'am_adam',
  'am_michael',
  'bf_emma',
  'bf_isabella',
  'bm_george',
  'bm_lewis',
];

/// Kokoro's positional style table: one 256-float vector per phoneme count.
const _styleDim = 256;

/// Longest phoneme sequence the model accepts.
const _maxPhonemes = 510;

/// Kokoro v0.19 always outputs 24 kHz.
const kokoroSampleRate = 24000;

/// Maps IPA characters to Kokoro token ids.
class KokoroVocabulary {
  KokoroVocabulary(this._ids);

  /// `tokens.txt` is `<symbol> <id>` per line — and one of the symbols is a
  /// space, so the separator is the *last* space, not the first.
  factory KokoroVocabulary.fromFile(String path) {
    final ids = <String, int>{};
    for (final line in File(path).readAsLinesSync()) {
      final split = line.lastIndexOf(' ');
      if (split <= 0) continue;
      final id = int.tryParse(line.substring(split + 1));
      if (id != null) ids[line.substring(0, split)] = id;
    }
    return KokoroVocabulary(ids);
  }

  final Map<String, int> _ids;

  bool contains(String symbol) => _ids.containsKey(symbol);

  /// Characters in [ipa] with no token, which would be silently dropped.
  Set<String> unknownSymbols(String ipa) =>
      ipa.split('').where((c) => !_ids.containsKey(c)).toSet();

  Int64List encode(String ipa) {
    final ids = <int>[0]; // leading pad
    for (final char in ipa.split('')) {
      final id = _ids[char];
      if (id != null) ids.add(id);
    }
    ids.add(0); // trailing pad
    return Int64List.fromList(ids);
  }
}

/// The style vectors from `voices.bin`, indexed by voice and phoneme count.
class KokoroVoiceBank {
  KokoroVoiceBank(this._data, this.voiceCount, this.styleBuckets);

  /// The bucket count is not fixed across Kokoro releases — v0.19 ships 511
  /// per voice, multi-lang v1.0 ships 510 — so it is derived from the file
  /// size against a known [voiceCount] rather than assumed.
  factory KokoroVoiceBank.fromFile(String path, {required int voiceCount}) {
    final bytes = File(path).readAsBytesSync();
    final floats = Float32List.sublistView(bytes);
    final buckets = floats.length ~/ (voiceCount * _styleDim);

    if (buckets == 0 || floats.length % (voiceCount * _styleDim) != 0) {
      throw StateError(
        '$path does not divide into $voiceCount voices '
        '(${floats.length} floats). Check voiceCount matches the bundle.',
      );
    }
    return KokoroVoiceBank(floats, voiceCount, buckets);
  }

  final Float32List _data;
  final int voiceCount;
  final int styleBuckets;

  /// Kokoro selects its style by how many phonemes are being spoken.
  Float32List styleFor({required int voice, required int phonemeCount}) {
    final bucket = phonemeCount.clamp(0, styleBuckets - 1);
    final offset = ((voice * styleBuckets) + bucket) * _styleDim;
    return Float32List.fromList(
      Float32List.sublistView(_data, offset, offset + _styleDim),
    );
  }
}

/// Splits IPA into runs the model can take, preferring punctuation then spaces.
///
/// Kokoro caps at [_maxPhonemes]; cutting mid-word would audibly clip, so this
/// backs up to the last natural boundary.
List<String> chunkIpa(String ipa, {int limit = _maxPhonemes}) {
  final chunks = <String>[];
  var rest = ipa.trim();

  while (rest.length > limit) {
    final window = rest.substring(0, limit);
    var cut = window.lastIndexOf(RegExp(r'[.,;:!?]'));
    if (cut < limit ~/ 4) cut = window.lastIndexOf(' ');
    if (cut < limit ~/ 4) cut = limit - 1;

    chunks.add(rest.substring(0, cut + 1).trim());
    rest = rest.substring(cut + 1).trim();
  }

  if (rest.isNotEmpty) chunks.add(rest);
  return chunks;
}

/// TTS that takes IPA rather than text, on a dedicated isolate.
class KokoroIpaTtsEngine implements TtsEngine {
  KokoroIpaTtsEngine._(
    this._isolate,
    this._fromWorker,
    this._toWorker,
    this._events,
    this._cancelFlag,
  );

  static Future<KokoroIpaTtsEngine> spawn(KokoroIpaConfig config) async {
    final cancelFlag = calloc<Int32>();
    final fromWorker = ReceivePort();
    final isolate = await Isolate.spawn(
      _workerMain,
      (fromWorker.sendPort, config, cancelFlag.address),
      debugName: 'kokoro-ipa',
    );

    final events = StreamController<(int, Object?)>.broadcast();
    final ready = Completer<SendPort>();

    fromWorker.listen((msg) {
      switch (msg) {
        case SendPort p:
          ready.complete(p);
        case (int id, Object? payload):
          events.add((id, payload));
      }
    });

    return KokoroIpaTtsEngine._(
      isolate,
      fromWorker,
      await ready.future,
      events,
      cancelFlag,
    );
  }

  final Isolate _isolate;
  final ReceivePort _fromWorker;
  final SendPort _toWorker;
  final StreamController<(int, Object?)> _events;
  final Pointer<Int32> _cancelFlag;

  @override
  int get sampleRate => kokoroSampleRate;

  int _nextId = 0;

  /// [ipa] must already be phonemes — see `devanagariToIpa`.
  @override
  Stream<AudioChunk> synthesize(String ipa) {
    final id = _nextId++;
    final out = StreamController<AudioChunk>();
    late StreamSubscription<(int, Object?)> sub;

    out.onListen = () {
      _cancelFlag.value = 0;
      sub = _events.stream.where((e) => e.$1 == id).listen((e) {
        switch (e.$2) {
          case AudioChunk chunk:
            out.add(chunk);
          case StateError error:
            out.addError(error);
          case null:
            sub.cancel();
            out.close();
        }
      });
      _toWorker.send((id, ipa));
    };

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

  static void _workerMain((SendPort, KokoroIpaConfig, int) args) {
    final (toMain, config, cancelAddress) = args;
    final cancelFlag = Pointer<Int32>.fromAddress(cancelAddress);

    _preloadOnnxRuntime(config.nativeLibraryPath);
    final env = DartONNX(loggingLevel: DartONNXLoggingLevel.error);
    final session = DartONNXSession.fromFile(env, config.model);
    final vocab = KokoroVocabulary.fromFile(config.tokens);
    final voices =
        KokoroVoiceBank.fromFile(config.voices, voiceCount: config.voiceCount);

    final inbox = ReceivePort();
    toMain.send(inbox.sendPort);

    inbox.listen((msg) {
      final (id, ipa) = msg as (int, String);
      try {
        // One run per chunk, so audio starts flowing before the whole
        // utterance is rendered.
        for (final chunk in chunkIpa(ipa)) {
          if (cancelFlag.value != 0) break;
          final audio = _synthesize(session, vocab, voices, config, chunk);
          if (audio.isNotEmpty) toMain.send((id, audio));
        }
      } catch (e) {
        toMain.send((id, StateError('Kokoro synthesis failed: $e')));
      }
      toMain.send((id, null));
    });
  }

  /// Loads ONNX Runtime by absolute path, ahead of dart_onnx.
  ///
  /// dart_onnx only accepts a library location through the `DART_ONNX_LIB_PATH`
  /// environment variable, and otherwise falls back to a bare
  /// `DynamicLibrary.open('libonnxruntime.so')` that only succeeds if the file
  /// happens to sit on the loader path. Environment variables are an awkward
  /// contract — a Dart process cannot set its own, and `source`ing a file
  /// without `export` sets a shell variable that `echo` prints but child
  /// processes never see, which fails in a way that looks like a missing file.
  ///
  /// Opening it here sidesteps all of that: the SONAME is `libonnxruntime.so`,
  /// so once it is in the process, dart_onnx's own bare open resolves to this
  /// already-loaded copy.
  static void _preloadOnnxRuntime(String? directory) {
    if (directory == null) return;

    final name = Platform.isWindows
        ? 'onnxruntime.dll'
        : Platform.isMacOS
            ? 'libonnxruntime.dylib'
            : 'libonnxruntime.so';
    final path = '$directory${Platform.pathSeparator}$name';

    if (!File(path).existsSync()) {
      throw StateError(
        'ONNX Runtime not found at $path.\n'
        'Pass --native-lib pointing at the directory holding $name '
        '(tool/fetch_models.sh puts one in native/).',
      );
    }
    DynamicLibrary.open(path);
  }

  static AudioChunk _synthesize(
    DartONNXSession session,
    KokoroVocabulary vocab,
    KokoroVoiceBank voices,
    KokoroIpaConfig config,
    String ipa,
  ) {
    final tokens = vocab.encode(ipa);
    // Padding is not spoken, so the style bucket keys off the real phonemes.
    final phonemeCount = tokens.length - 2;
    if (phonemeCount <= 0) return Float32List(0);

    final style = voices.styleFor(
      voice: config.voiceIndex.clamp(0, voices.voiceCount - 1),
      phonemeCount: phonemeCount,
    );

    final inputs = {
      'tokens': DartONNXTensor.int64(
        data: tokens,
        shape: [1, tokens.length],
      ),
      'style': DartONNXTensor.float32(data: style, shape: [1, _styleDim]),
      'speed': DartONNXTensor.float32(
        data: Float32List.fromList([config.speed]),
        shape: [1],
      ),
    };

    final outputs = session.run(inputs);
    try {
      final audio = outputs['audio']?.data;
      return audio is Float32List ? Float32List.fromList(audio) : Float32List(0);
    } finally {
      for (final tensor in inputs.values) {
        tensor.dispose();
      }
      for (final tensor in outputs.values) {
        tensor.dispose();
      }
    }
  }
}
