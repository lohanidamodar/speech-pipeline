import 'dart:io';

import 'package:voice_models/voice_models.dart';

/// The native libraries this package loads, and where to find them.
///
/// Neither is a model, so neither can come from the model store — they are
/// compiled code, matched to the package versions in `pubspec.yaml`. Rather
/// than making their location a required setting, the obvious places are
/// searched: beside the executable, which is what an unpacked release looks
/// like, then a `runtime` directory beside the models, which several PopupBits
/// apps can share one copy of.
enum NativeLibrary {
  /// audio.cpp — synthesis, cloning, voice design.
  audioCpp('audiocpp_c', 'libaudiocpp_c'),

  /// sherpa-onnx — recognition and voice activity.
  sherpaOnnx('sherpa-onnx-c-api', 'libsherpa-onnx-c-api');

  const NativeLibrary(this._windowsName, this._unixName);

  final String _windowsName;
  final String _unixName;

  /// The file name on this platform.
  String get fileName => switch (Platform.operatingSystem) {
        'windows' => '$_windowsName.dll',
        'macos' => '$_unixName.dylib',
        _ => '$_unixName.so',
      };
}

/// Where [library] is, or null if it is nowhere this knows to look.
///
/// A null answer is not fatal — the loader falls back to the system search
/// path — but it is worth reporting, because the failure that follows happens
/// inside native code and says nothing useful.
String? resolveNativeLibraryDir(
  NativeLibrary library, [
  String? configured,
]) {
  for (final dir in nativeLibrarySearchPath(configured)) {
    if (File('$dir${Platform.pathSeparator}${library.fileName}').existsSync()) {
      return dir;
    }
  }
  return null;
}

/// The directories searched, in order.
List<String> nativeLibrarySearchPath([String? configured]) {
  final sep = Platform.pathSeparator;
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  return [
    if (configured != null && configured.trim().isNotEmpty) configured.trim(),
    exeDir,
    // Where Flutter puts a Windows app's bundled DLLs.
    '$exeDir${sep}blobs',
    '$exeDir${sep}runtime',
    '${popupBitsDataDir()}${sep}runtime',
  ];
}

/// What to tell someone when a library is missing.
String missingNativeLibraryMessage(
  NativeLibrary library, [
  String? configured,
]) {
  final looked =
      nativeLibrarySearchPath(configured).map((p) => '  $p').join('\n');
  final source = switch (library) {
    NativeLibrary.audioCpp => 'https://github.com/0xShug0/audio.cpp/releases',
    NativeLibrary.sherpaOnnx => 'https://github.com/k2-fsa/sherpa-onnx/releases',
  };
  return 'Could not find ${library.fileName}. Looked in:\n$looked\n\n'
      'Download it from $source and put it in one of those directories.';
}
