import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// Loads the native sherpa-onnx library for the calling isolate.
///
/// Bindings are per-isolate state, so every isolate that touches a sherpa
/// engine must call this — the STT and TTS workers do it themselves on start.
///
/// [nativeLibraryPath] is the directory holding `libsherpa-onnx-c-api.so`
/// (`.dylib` / `.dll`). Pass null in Flutter builds, where the plugin puts the
/// library somewhere the system loader already looks.
void initSherpaBindings([String? nativeLibraryPath]) =>
    sherpa.initBindings(nativeLibraryPath);
