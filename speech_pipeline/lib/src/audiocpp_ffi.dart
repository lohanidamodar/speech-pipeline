import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// --- C ABI mirror (capi/audiocpp_c.h) ---------------------------------------

final class _AcAudio extends Struct {
  external Pointer<Float> samples;
  @Int32()
  external int nSamples;
  @Int32()
  external int sampleRate;
  @Int32()
  external int channels;
}

final class _AcModelParams extends Struct {
  external Pointer<Utf8> modelPath;
  external Pointer<Utf8> family;
  @Int32()
  external int backend;
  @Int32()
  external int device;
  @Int32()
  external int threads;
}

final class _AcTtsParams extends Struct {
  external Pointer<Utf8> text;
  external Pointer<Utf8> language;
  external Pointer<Utf8> instruct;
  external Pointer<Utf8> refWavPath;
  external Pointer<Utf8> refText;
}

/// Which ggml backend the engine runs on.
enum AcBackend { cpu, cuda, vulkan, metal, hip, best }

class _Bindings {
  _Bindings(DynamicLibrary lib)
    : init = lib
          .lookupFunction<
            Pointer<Void> Function(Pointer<_AcModelParams>),
            Pointer<Void> Function(Pointer<_AcModelParams>)
          >('ac_init'),
      free = lib
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('ac_free'),
      synthesize = lib
          .lookupFunction<
            Int32 Function(
              Pointer<Void>,
              Pointer<_AcTtsParams>,
              Pointer<_AcAudio>,
            ),
            int Function(
              Pointer<Void>,
              Pointer<_AcTtsParams>,
              Pointer<_AcAudio>,
            )
          >('ac_synthesize'),
      audioFree = lib
          .lookupFunction<
            Void Function(Pointer<_AcAudio>),
            void Function(Pointer<_AcAudio>)
          >('ac_audio_free'),
      lastError = lib
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'ac_last_error',
          ),
      version = lib
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'ac_version',
          );

  final Pointer<Void> Function(Pointer<_AcModelParams>) init;
  final void Function(Pointer<Void>) free;
  final int Function(Pointer<Void>, Pointer<_AcTtsParams>, Pointer<_AcAudio>)
  synthesize;
  final void Function(Pointer<_AcAudio>) audioFree;
  final Pointer<Utf8> Function() lastError;
  final Pointer<Utf8> Function() version;
}

class AcException implements Exception {
  AcException(this.message);
  final String message;
  @override
  String toString() => 'AcException: $message';
}

/// Synthesised audio, already copied out of native memory.
class AcAudio {
  AcAudio(this.samples, this.sampleRate, this.channels);
  final Float32List samples;
  final int sampleRate;
  final int channels;

  double get seconds => samples.length / (sampleRate * channels);
}

/// audio.cpp over FFI.
///
/// Holds the model resident between calls, which is the entire point: a
/// one-shot CLI pays the weight-load cost on every utterance and that cost
/// dominates. Keeping the session alive is what turns this from batch tooling
/// into something interactive.
class AudioCpp {
  AudioCpp._(this._b, this._ctx);

  /// [libraryPath] may be the directory holding the shared library or the
  /// library file itself — both readings are natural, and guessing wrong
  /// produces a doubled-up path that is baffling to read.
  static DynamicLibrary _open(String? libraryPath) {
    final name = Platform.isWindows
        ? 'audiocpp_c.dll'
        : Platform.isMacOS
        ? 'libaudiocpp_c.dylib'
        : 'libaudiocpp_c.so';
    // No path at all: let the OS loader search, which is how a Flutter build
    // finds the library bundled into the app.
    if (libraryPath == null) return DynamicLibrary.open(name);

    final path = File(libraryPath).existsSync()
        ? libraryPath
        : '$libraryPath${Platform.pathSeparator}$name';
    if (!File(path).existsSync()) {
      throw AcException('Native library not found at $path');
    }
    return DynamicLibrary.open(path);
  }

  /// [modelPath] is a GGUF file or model package directory; [family] is the
  /// engine family name such as `omnivoice` or `qwen3_tts`.
  factory AudioCpp.open({
    required String modelPath,
    required String family,
    String? libraryPath,
    AcBackend backend = AcBackend.cpu,
    int device = 0,
    int threads = 4,
  }) {
    final b = _Bindings(_open(libraryPath));
    final p = calloc<_AcModelParams>();
    p.ref
      ..modelPath = modelPath.toNativeUtf8()
      ..family = family.toNativeUtf8()
      ..backend = backend.index
      ..device = device
      ..threads = threads;
    try {
      final ctx = b.init(p);
      if (ctx == nullptr) {
        throw AcException(b.lastError().toDartString());
      }
      return AudioCpp._(b, ctx);
    } finally {
      calloc.free(p.ref.modelPath);
      calloc.free(p.ref.family);
      calloc.free(p);
    }
  }

  final _Bindings _b;
  Pointer<Void> _ctx;

  String get version => _b.version().toDartString();

  /// Supplying [refWavPath] clones that voice; OmniVoice also wants
  /// [refText], the transcript of the reference, or the clone degrades.
  AcAudio synthesize(
    String text, {
    String? language,
    String? instruct,
    String? refWavPath,
    String? refText,
  }) {
    if (_ctx == nullptr) throw AcException('context already disposed');

    final p = calloc<_AcTtsParams>();
    final out = calloc<_AcAudio>();
    // Text crosses as UTF-8 bytes, never via a shell — a non-UTF-8 console
    // codepage silently turns non-ASCII into '?' and the model synthesises it.
    p.ref
      ..text = text.toNativeUtf8()
      ..language = language == null ? nullptr : language.toNativeUtf8()
      ..instruct = instruct == null ? nullptr : instruct.toNativeUtf8()
      ..refWavPath = refWavPath == null ? nullptr : refWavPath.toNativeUtf8()
      ..refText = refText == null ? nullptr : refText.toNativeUtf8();

    try {
      final status = _b.synthesize(_ctx, p, out);
      if (status != 0) throw AcException(_b.lastError().toDartString());

      final n = out.ref.nSamples;
      final copy = Float32List(n);
      final view = out.ref.samples.asTypedList(n);
      copy.setAll(0, view);
      final audio = AcAudio(copy, out.ref.sampleRate, out.ref.channels);
      _b.audioFree(out);
      return audio;
    } finally {
      for (final ptr in [
        p.ref.text,
        p.ref.language,
        p.ref.instruct,
        p.ref.refWavPath,
        p.ref.refText,
      ]) {
        if (ptr != nullptr) calloc.free(ptr);
      }
      calloc.free(p);
      calloc.free(out);
    }
  }

  void dispose() {
    if (_ctx == nullptr) return;
    _b.free(_ctx);
    _ctx = nullptr;
  }
}
