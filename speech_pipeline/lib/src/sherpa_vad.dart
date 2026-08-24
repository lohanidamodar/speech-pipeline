import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'engines.dart';

/// Silero VAD via sherpa-onnx.
///
/// Runs on the calling isolate: the model is ~600 KB and scores a 32 ms frame
/// in well under a millisecond, so keeping it off an isolate hop is what makes
/// barge-in feel immediate.
class SherpaVadEngine implements VadEngine {
  SherpaVadEngine._(this._vad, this._preRollSamples, this._historySamples);

  /// [model] is the path to `silero_vad.onnx`.
  ///
  /// [preRoll] is audio retained from *before* the detector fired, prepended to
  /// each emitted segment. Silero only confirms speech after
  /// [minSpeechDuration] has elapsed and starts the segment there, so without
  /// this the opening word is cut off — "the quick brown fox" is recognised as
  /// "brown fox".
  factory SherpaVadEngine({
    required String model,
    double threshold = 0.5,
    double minSilenceDuration = 0.35,
    double minSpeechDuration = 0.25,
    double maxSpeechDuration = 20.0,
    double bufferSizeInSeconds = 30.0,
    double preRoll = 0.3,
  }) {
    final config = sherpa.VadModelConfig(
      sileroVad: sherpa.SileroVadModelConfig(
        model: model,
        threshold: threshold,
        minSilenceDuration: minSilenceDuration,
        minSpeechDuration: minSpeechDuration,
        maxSpeechDuration: maxSpeechDuration,
      ),
      sampleRate: kSampleRate,
      numThreads: 1,
      debug: false,
    );
    return SherpaVadEngine._(
      sherpa.VoiceActivityDetector(
        config: config,
        bufferSizeInSeconds: bufferSizeInSeconds,
      ),
      (preRoll * kSampleRate).round(),
      // A segment is only emitted once it ends, so reaching back to its onset
      // means retaining a whole utterance plus the pre-roll behind it.
      ((maxSpeechDuration + preRoll + 1) * kSampleRate).round(),
    );
  }

  final sherpa.VoiceActivityDetector _vad;
  final int _preRollSamples;
  final int _historySamples;

  bool _wasDetected = false;

  /// Recent input kept as arrived, so trimming is a dequeue rather than a copy
  /// of the whole history on every frame.
  final Queue<Float32List> _recent = Queue();
  int _recentLength = 0;

  /// Absolute sample index of the first retained sample. sherpa counts segment
  /// offsets from the first sample ever fed, so these share an origin.
  int _recentStart = 0;

  @override
  Stream<VadEvent> process(Stream<AudioChunk> audio) async* {
    await for (final chunk in audio) {
      _vad.acceptWaveform(chunk);
      _remember(chunk);

      // Rising edge of the detector — speech has begun but isn't finished.
      final detected = _vad.isDetected();
      if (detected && !_wasDetected) yield const SpeechStarted();
      _wasDetected = detected;

      yield* _drain();
    }

    // The source ended. A segment still open at that moment — the common case
    // when replaying a file, and what happens on a live mic at shutdown — is
    // held inside the detector and would otherwise be discarded unspoken.
    _vad.flush();
    yield* _drain();
    _wasDetected = false;
  }

  Stream<VadEvent> _drain() async* {
    while (!_vad.isEmpty()) {
      yield SpeechEnded(_withPreRoll(_vad.front()));
      _vad.pop();
    }
  }

  void _remember(AudioChunk chunk) {
    // Copy: callers may hand us a view onto a buffer they go on to reuse.
    _recent.add(Float32List.fromList(chunk));
    _recentLength += chunk.length;

    while (_recent.isNotEmpty &&
        _recentLength - _recent.first.length >= _historySamples) {
      final dropped = _recent.removeFirst();
      _recentLength -= dropped.length;
      _recentStart += dropped.length;
    }
  }

  /// Prepends whatever retained audio sits immediately before the segment.
  AudioChunk _withPreRoll(sherpa.SpeechSegment segment) {
    final from = (segment.start - _preRollSamples).clamp(
      _recentStart,
      _recentStart + _recentLength,
    );
    final available = segment.start - from;
    if (available <= 0) return segment.samples;

    final out = Float32List(available + segment.samples.length);
    _copyRange(from, segment.start, out);
    out.setAll(available, segment.samples);
    return out;
  }

  /// Copies absolute sample range `[fromAbs, toAbs)` out of the retained chunks.
  void _copyRange(int fromAbs, int toAbs, Float32List out) {
    var chunkStart = _recentStart;
    var written = 0;

    for (final chunk in _recent) {
      final chunkEnd = chunkStart + chunk.length;
      if (chunkEnd > fromAbs && chunkStart < toAbs) {
        final s = fromAbs > chunkStart ? fromAbs - chunkStart : 0;
        final e = toAbs < chunkEnd ? toAbs - chunkStart : chunk.length;
        out.setAll(written, Float32List.sublistView(chunk, s, e));
        written += e - s;
      }
      chunkStart = chunkEnd;
      if (chunkStart >= toAbs) break;
    }
  }

  /// Drop buffered audio and detector state, e.g. after a cancelled turn.
  void reset() {
    _vad.reset();
    _vad.clear();
    _wasDetected = false;
    _recent.clear();
    _recentLength = 0;
  }

  @override
  Future<void> dispose() async => _vad.free();
}
