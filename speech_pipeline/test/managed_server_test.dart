import 'dart:io';

import 'package:speech_pipeline/speech_pipeline.dart';
import 'package:test/test.dart';

void main() {
  late ManagedLlmServer server;
  late Directory dir;

  setUp(() async {
    server = ManagedLlmServer();
    dir = await Directory.systemTemp.createTemp('server');
  });

  tearDown(() async {
    await server.dispose();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('starts stopped', () {
    expect(server.current.state, ServerState.stopped);
    expect(server.current.isRunning, isFalse);
  });

  test('says which file is missing rather than failing opaquely', () async {
    await expectLater(
      server.start(
        executable: '${dir.path}/no-such-binary',
        modelPath: '${dir.path}/none.gguf',
      ),
      throwsA(
        isA<ManagedServerException>().having(
          (e) => e.message,
          'message',
          contains('no-such-binary'),
        ),
      ),
    );
    expect(server.current.state, ServerState.failed);
  });

  test('checks the model too, not only the binary', () async {
    final fake = File('${dir.path}/fake-server')
      ..writeAsStringSync('#!/bin/sh');
    await expectLater(
      server.start(executable: fake.path, modelPath: '${dir.path}/none.gguf'),
      throwsA(
        isA<ManagedServerException>().having(
          (e) => e.message,
          'message',
          contains('none.gguf'),
        ),
      ),
    );
  });

  test('surfaces what a dying process printed', () async {
    // A server that cannot load its weights prints why and exits. That line is
    // the only useful thing to show, so waiting for the health timeout instead
    // would throw away the answer.
    if (Platform.isWindows) return;
    final script = File('${dir.path}/broken')
      ..writeAsStringSync(
        '#!/bin/sh\necho "error: failed to load model" >&2\nexit 1\n',
      );
    await Process.run('chmod', ['+x', script.path]);
    final model = File('${dir.path}/m.gguf')..writeAsStringSync('x');

    await expectLater(
      server.start(
        executable: script.path,
        modelPath: model.path,
        timeout: const Duration(seconds: 20),
      ),
      throwsA(
        isA<ManagedServerException>().having(
          (e) => e.message,
          'message',
          allOf(contains('exited'), contains('failed to load model')),
        ),
      ),
    );
    expect(server.current.state, ServerState.failed);
  }, timeout: const Timeout(Duration(seconds: 30)));

  _launcher();

  test('stopping when nothing is running is harmless', () async {
    await server.stop();
    expect(server.current.state, ServerState.stopped);
  });

  test('status reads as something a person can act on', () {
    expect(const ServerStatus(ServerState.stopped).toString(), 'Stopped');
    expect(
      const ServerStatus(
        ServerState.running,
        baseUrl: 'http://x/v1',
      ).toString(),
      contains('http://x/v1'),
    );
    expect(
      const ServerStatus(
        ServerState.failed,
        detail: 'out of memory',
      ).toString(),
      contains('out of memory'),
    );
  });
}

void _launcher() {
  test('a launcher prefix runs the real binary behind it', () async {
    // How a Windows app starts a Linux server built inside WSL. Verified by
    // what the process is asked to run, since spawning WSL from a test is not
    // portable.
    if (Platform.isWindows) return;
    final dir = Directory.systemTemp.createTempSync('launcher');
    addTearDown(() => dir.deleteSync(recursive: true));

    // `sh -c 'echo ... ; exit 1'` stands in for the launcher: it fails, and
    // the failure has to carry the arguments it was handed.
    final echo = File('${dir.path}/launcher')
      ..writeAsStringSync(
        '#!/bin/sh\necho "error: args are: \$@" >&2\nexit 1\n',
      );
    await Process.run('chmod', ['+x', echo.path]);

    final server = ManagedLlmServer();
    addTearDown(server.dispose);

    await expectLater(
      server.start(
        executable: echo.path,
        leadingArgs: const ['-e', '/home/you/llama-server'],
        modelPath: '/home/you/model.gguf',
        verifyPaths: false,
        timeout: const Duration(seconds: 20),
      ),
      throwsA(
        isA<ManagedServerException>().having(
          (e) => e.message,
          'message',
          allOf(contains('/home/you/llama-server'), contains('model.gguf')),
        ),
      ),
    );
  }, timeout: const Timeout(Duration(seconds: 30)));
}
