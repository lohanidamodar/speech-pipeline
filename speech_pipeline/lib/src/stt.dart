import 'dart:io';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'sherpa_init.dart';

/// Speech recognition for the reference clip.
///
/// OmniVoice clones far better when given the transcript of the reference, and
/// typing Devanagari on a phone is miserable — so the recording transcribes
/// itself. Nepali and Sanskrit use the exported AI4Bharat IndicConformer;
/// English uses SenseVoice.
class Stt {
  Stt._(this._recognizer);

  static Stt open({
    required String modelsDir,
    required String language,
    String? nativeLibraryPath,
  }) {
    // Pins our onnxruntime.dll ahead of the System32 one; see
    // initSherpaBindings for why that matters on Windows.
    initSherpaBindings(nativeLibraryPath);

    final sherpa.OfflineModelConfig model;
    if (language == 'en') {
      final dir =
          '$modelsDir/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17';
      model = sherpa.OfflineModelConfig(
        senseVoice: sherpa.OfflineSenseVoiceModelConfig(
          model: '$dir/model.int8.onnx',
          useInverseTextNormalization: true,
        ),
        tokens: '$dir/tokens.txt',
        numThreads: 2,
        debug: false,
      );
    } else {
      final code = language == 'sa' ? 'sa' : 'ne';
      final dir = '$modelsDir/indicconformer-$code';
      if (!File('$dir/model.onnx').existsSync()) {
        throw StateError(
          'No recogniser at $dir — run tool/export_indicconformer.py',
        );
      }
      model = sherpa.OfflineModelConfig(
        nemoCtc: sherpa.OfflineNemoEncDecCtcModelConfig(
          model: '$dir/model.onnx',
        ),
        tokens: '$dir/tokens.txt',
        numThreads: 2,
        debug: false,
      );
    }
    return Stt._(
      sherpa.OfflineRecognizer(sherpa.OfflineRecognizerConfig(model: model)),
    );
  }

  final sherpa.OfflineRecognizer _recognizer;

  String transcribe(Float32List samples, int sampleRate) {
    final stream = _recognizer.createStream();
    try {
      stream.acceptWaveform(samples: samples, sampleRate: sampleRate);
      _recognizer.decode(stream);
      return _recognizer.getResult(stream).text.trim();
    } finally {
      stream.free();
    }
  }

  void dispose() => _recognizer.free();
}
