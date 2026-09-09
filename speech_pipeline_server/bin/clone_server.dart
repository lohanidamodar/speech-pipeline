import 'dart:io';

import 'package:args/args.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:speech_pipeline_server/clone_cli.dart';

/// Local web UI for recording a voice and cloning it.
///
/// Two engines sit behind one endpoint, because no single model covers all
/// three languages: Qwen3-TTS (via llama.cpp) handles English, OmniVoice
/// handles Nepali and Sanskrit. Both are native binaries — no Python.
///
///   dart run bin/clone_server.dart \
///     --llama-tts ~/llama.cpp/build/bin/llama-tts \
///     --qwen-dir  ~/qwen3tts \
///     --omnivoice ~/omnivoice.cpp/build/omnivoice-tts \
///     --omni-dir  ~/omnivoice.cpp/models
Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('port', defaultsTo: '8080')
    ..addOption('web', defaultsTo: 'speech_pipeline_server/web')
    ..addOption('llama-tts', help: 'Path to the llama-tts binary (English).')
    ..addOption('qwen-dir', help: 'Directory with the Qwen3-TTS GGUFs.')
    ..addOption('omnivoice', help: 'Path to omnivoice-tts (Nepali/Sanskrit).')
    ..addOption('omni-dir', help: 'Directory with the OmniVoice GGUFs.')
    ..addOption('steps', defaultsTo: '16', help: 'OmniVoice MaskGIT steps.');

  final args = parser.parse(argv);
  final engines = CloneEngines(
    llamaTts: args.option('llama-tts'),
    qwenDir: args.option('qwen-dir'),
    omnivoice: args.option('omnivoice'),
    omniDir: args.option('omni-dir'),
    steps: args.option('steps')!,
  );
  final webRoot = Directory(args.option('web')!);

  if (!webRoot.existsSync()) {
    stderr.writeln('No web root at ${webRoot.path}');
    exitCode = 1;
    return;
  }

  final workDir = Directory.systemTemp.createTempSync('voiceclone');

  Future<Response> handler(Request req) async {
    if (req.method == 'POST' && req.url.path == 'api/clone') {
      return _clone(req, engines, workDir);
    }
    if (req.method != 'GET') return Response.notFound('');

    final name = req.url.path.isEmpty ? 'index.html' : req.url.path;
    final file = File('${webRoot.path}/$name');
    if (!file.existsSync()) return Response.notFound('not found');
    return Response.ok(
      file.readAsBytesSync(),
      headers: {'content-type': _mime(name)},
    );
  }

  final server = await io.serve(
    const Pipeline().addHandler(handler),
    InternetAddress.loopbackIPv4,
    int.parse(args.option('port')!),
  );

  stdout.writeln('Voice cloning UI  →  http://localhost:${server.port}');
  stdout.writeln(engines.describe());
  stdout.writeln(
    '\nMicrophone capture needs a secure context; localhost counts,'
    ' so open it on this machine rather than over the LAN.',
  );
}

String _mime(String name) => switch (name.split('.').last) {
  'html' => 'text/html; charset=utf-8',
  'js' => 'text/javascript',
  'css' => 'text/css',
  'wav' => 'audio/wav',
  _ => 'application/octet-stream',
};

Future<Response> _clone(Request req, CloneEngines engines, Directory work) async {
  final lang = req.headers['x-lang'] ?? 'en';
  final text = Uri.decodeComponent(req.headers['x-text'] ?? '').trim();
  final refText = Uri.decodeComponent(req.headers['x-ref-text'] ?? '').trim();
  if (text.isEmpty) return Response.badRequest(body: 'No text supplied.');

  final bytes = await req.read().expand((c) => c).toList();
  if (bytes.length < 1000) {
    return Response.badRequest(body: 'Recording too short or empty.');
  }

  final stamp = DateTime.now().microsecondsSinceEpoch;
  final ref = File('${work.path}/ref_$stamp.wav')..writeAsBytesSync(bytes);
  final out = File('${work.path}/out_$stamp.wav');

  final String exe;
  final List<String>? cmdArgs;

  if (lang == 'en') {
    if (!engines.hasEnglish) {
      return Response.internalServerError(
        body: 'English engine not configured (--llama-tts / --qwen-dir).',
      );
    }
    exe = engines.llamaTts!;
    cmdArgs = engines.englishArgs(ref.path, text, out.path);
  } else {
    if (!engines.hasIndic) {
      return Response.internalServerError(
        body: 'OmniVoice not configured (--omnivoice / --omni-dir).',
      );
    }
    if (refText.isEmpty) {
      return Response.badRequest(
        body: 'OmniVoice needs the transcript of the reference recording.',
      );
    }
    final rt = File('${work.path}/ref_$stamp.txt')..writeAsStringSync(refText);
    exe = engines.omnivoice!;
    cmdArgs = engines.indicArgs(lang, ref.path, rt.path, out.path);
  }

  if (cmdArgs == null) {
    return Response.internalServerError(body: 'Model files not found on disk.');
  }

  stdout.writeln(
    '[clone] $lang  "${text.length > 60 ? "${text.substring(0, 60)}…" : text}"',
  );
  final started = DateTime.now();
  final why = await runClone(
    exe: exe,
    args: cmdArgs,
    out: out,
    stdinText: lang == 'en' ? null : text,
  );
  final ms = DateTime.now().difference(started).inMilliseconds;
  if (why != null) {
    stdout.writeln('[clone] failed in ${ms}ms');
    return Response.internalServerError(body: why);
  }

  stdout.writeln('[clone] ok in ${ms}ms → ${out.lengthSync() ~/ 1024} KB');
  return Response.ok(
    out.readAsBytesSync(),
    headers: {'content-type': 'audio/wav', 'x-elapsed-ms': '$ms'},
  );
}
