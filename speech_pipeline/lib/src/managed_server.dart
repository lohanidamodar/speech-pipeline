import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

/// What a [ManagedLlmServer] is doing.
enum ServerState { stopped, starting, running, failed }

class ServerStatus {
  const ServerStatus(this.state, {this.detail, this.baseUrl});

  final ServerState state;

  /// Why it failed, or the last line the process printed while starting.
  final String? detail;

  final String? baseUrl;

  bool get isRunning => state == ServerState.running;

  @override
  String toString() => switch (state) {
    ServerState.stopped => 'Stopped',
    ServerState.starting => 'Starting… ${detail ?? ''}'.trim(),
    ServerState.running => 'Running at $baseUrl',
    ServerState.failed => 'Failed: ${detail ?? 'unknown error'}',
  };
}

/// Runs a local inference server as a child process.
///
/// Desktop only, and deliberately not bundled: the binary is whatever the user
/// points at — `llama-server`, `llama-server.exe`, or `wsl.exe -e …` for a
/// server built inside WSL. Shipping one would mean carrying a large native
/// binary per platform and keeping it current, and it still would not work on
/// a phone. On mobile the answer is in-process inference, not a subprocess.
///
/// The process is a child of this one, so it dies with the app. That is the
/// intent: a forgotten server holding several gigabytes of weights is exactly
/// the kind of thing nobody notices until the machine is out of memory.
class ManagedLlmServer {
  ManagedLlmServer({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Process? _process;
  final _status = StreamController<ServerStatus>.broadcast();
  ServerStatus _current = const ServerStatus(ServerState.stopped);

  Stream<ServerStatus> get status => _status.stream;
  ServerStatus get current => _current;

  /// The most recent process output, newest last. Kept short — it exists to
  /// explain a failure, not to be a log viewer.
  final List<String> recentOutput = [];

  void _set(ServerStatus status) {
    _current = status;
    if (!_status.isClosed) _status.add(status);
  }

  /// Starts [executable] serving [modelPath] on [port].
  ///
  /// Returns the base URL once the server answers, or throws with what the
  /// process printed — a server that dies on startup prints the reason and
  /// then exits, and that reason is the only useful thing to show.
  /// [leadingArgs] go before the server's own flags, which is what makes a
  /// launcher work: `wsl.exe -e /home/you/llama.cpp/build/bin/llama-server`
  /// runs a Linux build from a Windows app. Set [verifyPaths] false in that
  /// case — the paths then live inside the launcher's filesystem and this
  /// process cannot stat them.
  Future<String> start({
    required String executable,
    required String modelPath,
    int port = 8080,
    List<String> leadingArgs = const [],
    List<String> extraArgs = const [],
    int contextSize = 4096,
    bool verifyPaths = true,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    await stop();

    if (verifyPaths && !File(executable).existsSync()) {
      final failure = 'No server binary at $executable';
      _set(ServerStatus(ServerState.failed, detail: failure));
      throw ManagedServerException(failure);
    }
    if (verifyPaths && !File(modelPath).existsSync()) {
      final failure = 'No model file at $modelPath';
      _set(ServerStatus(ServerState.failed, detail: failure));
      throw ManagedServerException(failure);
    }

    final baseUrl = 'http://127.0.0.1:$port/v1';
    _set(const ServerStatus(ServerState.starting));
    recentOutput.clear();

    try {
      _process = await Process.start(executable, [
        ...leadingArgs,
        '-m', modelPath,
        '--port', '$port',
        // Loopback only. A local model is the private option; binding it to
        // every interface would quietly put it on the network.
        '--host', '127.0.0.1',
        '-c', '$contextSize',
        ...extraArgs,
      ]);
    } on ProcessException catch (e) {
      final failure = 'Could not start $executable: ${e.message}';
      _set(ServerStatus(ServerState.failed, detail: failure));
      throw ManagedServerException(failure);
    }

    _watch(_process!.stdout);
    _watch(_process!.stderr);

    // A process that exits during startup will never answer /health, so the
    // wait has to end on either signal rather than only on the timeout.
    final died = Completer<int>();
    unawaited(
      _process!.exitCode.then((code) {
        if (!died.isCompleted) died.complete(code);
      }),
    );

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (died.isCompleted) {
        final failure = 'Server exited: ${_lastMeaningfulLine()}';
        _set(ServerStatus(ServerState.failed, detail: failure));
        throw ManagedServerException(failure);
      }
      if (await _healthy(port)) {
        _set(ServerStatus(ServerState.running, baseUrl: baseUrl));
        return baseUrl;
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }

    await stop();
    const failure = 'Timed out waiting for the server to answer';
    _set(const ServerStatus(ServerState.failed, detail: failure));
    throw ManagedServerException(failure);
  }

  Future<bool> _healthy(int port) async {
    try {
      final r = await _client
          .get(Uri.parse('http://127.0.0.1:$port/health'))
          .timeout(const Duration(seconds: 2));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  void _watch(Stream<List<int>> stream) {
    stream.transform(const SystemEncoding().decoder).listen((chunk) {
      for (final line in chunk.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        recentOutput.add(trimmed);
        if (recentOutput.length > 40) recentOutput.removeAt(0);
        if (_current.state == ServerState.starting) {
          _set(ServerStatus(ServerState.starting, detail: trimmed));
        }
      }
    }, onError: (_) {});
  }

  /// The last line that looks like an explanation rather than progress noise.
  String _lastMeaningfulLine() {
    for (final line in recentOutput.reversed) {
      if (line.toLowerCase().contains('error') ||
          line.toLowerCase().contains('failed') ||
          line.toLowerCase().contains('cannot')) {
        return line;
      }
    }
    return recentOutput.isEmpty ? 'no output' : recentOutput.last;
  }

  Future<void> stop() async {
    final process = _process;
    _process = null;
    if (process == null) return;

    process.kill();
    // SIGTERM is usually enough; a server mid-load may need more insistence.
    await process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    _set(const ServerStatus(ServerState.stopped));
  }

  Future<void> dispose() async {
    await stop();
    await _status.close();
    _client.close();
  }
}

class ManagedServerException implements Exception {
  const ManagedServerException(this.message);
  final String message;

  @override
  String toString() => message;
}
