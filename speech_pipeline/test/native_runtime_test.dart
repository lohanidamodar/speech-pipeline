import 'dart:io';

import 'package:speech_pipeline/speech_pipeline.dart';
import 'package:test/test.dart';

void main() {
  test('each library knows its name on this platform', () {
    for (final library in NativeLibrary.values) {
      expect(library.fileName, isNotEmpty);
      expect(
        library.fileName,
        endsWith(switch (Platform.operatingSystem) {
          'windows' => '.dll',
          'macos' => '.dylib',
          _ => '.so',
        }),
      );
    }
  });

  test('looks beside the executable first, then the shared runtime', () {
    // A shipped build carries its own copy; a developer build finds the one
    // every PopupBits app shares.
    final path = nativeLibrarySearchPath();
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    expect(path.first, exeDir);
    expect(path.last, endsWith('${Platform.pathSeparator}runtime'));
  });

  test('a configured directory wins', () {
    expect(nativeLibrarySearchPath('/somewhere').first, '/somewhere');
  });

  test('a blank setting is not searched', () {
    // Otherwise an unset environment variable becomes a lookup in '', which
    // resolves to the working directory and finds nothing.
    expect(nativeLibrarySearchPath('   '), nativeLibrarySearchPath(null));
  });

  test('an empty directory holds nothing', () {
    final dir = Directory.systemTemp.createTempSync('runtime');
    addTearDown(() => dir.deleteSync(recursive: true));
    expect(resolveNativeLibraryDir(NativeLibrary.audioCpp, dir.path), isNull);
  });

  test('a found library reports its directory', () {
    final dir = Directory.systemTemp.createTempSync('runtime');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}${Platform.pathSeparator}'
            '${NativeLibrary.sherpaOnnx.fileName}')
        .writeAsStringSync('');

    expect(resolveNativeLibraryDir(NativeLibrary.sherpaOnnx, dir.path), dir.path);
    // The other library is still missing, and is reported separately.
    expect(resolveNativeLibraryDir(NativeLibrary.audioCpp, dir.path), isNull);
  });

  test('the message names where it looked and where to get it', () {
    final message = missingNativeLibraryMessage(NativeLibrary.audioCpp, '/x');
    expect(message, contains('/x'));
    expect(message, contains('audio.cpp/releases'));
  });
}
