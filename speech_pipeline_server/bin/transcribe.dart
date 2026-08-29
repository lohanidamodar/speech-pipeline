import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:speech_pipeline/speech_pipeline.dart';

/// Transcribes a .wav file — a real recording, not synthesised speech.
///
/// This is the honest test of a recogniser. Round-tripping our own TTS flatters
/// it: the audio is clean, evenly paced, and in Sanskrit's case spoken by an
/// English voice the model never trained on.
///
///   dart run bin/transcribe.dart --lang ne --input recording.wav
Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('input', mandatory: true, help: 'Path to a .wav file.')
    ..addOption('lang', defaultsTo: 'en', allowed: ['en', 'ne', 'sa'])
    ..addOption('models', defaultsTo: 'models')
    ..addOption('native-lib')
    ..addOption('out', help: 'Write a Markdown transcript here.')
    ..addOption(
      'vocabulary',
      help: 'JSON list of corrections. Defaults to <models>/vocabulary.json.',
    )
    ..addFlag(
      'polish',
      negatable: false,
      help: 'Tidy each paragraph with the configured LLM (see SP_LLM_*).',
    )
    ..addOption('title', help: 'Heading for the Markdown file.')
    ..addOption(
      'gap',
      defaultsTo: '2.0',
      help: 'Seconds of silence that start a new paragraph.',
    )
    ..addFlag(
      'whole',
      help: 'Skip the VAD and decode the file in one go.',
      negatable: false,
    );

  final args = parser.parse(argv);
  final input = File(args.option('input')!);
  if (!input.existsSync()) {
    stderr.writeln('No such file: ${input.path}');
    exitCode = 1;
    return;
  }

  final setup = PipelineSetup(
    language: PipelineLanguage.byCode(args.option('lang')!),
    modelsDir: args.option('models'),
    nativeLibraryPath: args.option('native-lib'),
  );

  initSherpaBindings(setup.nativeLibraryPath);

  final wave = sherpa.readWave(input.path);
  if (wave.samples.isEmpty || wave.sampleRate == 0) {
    // readWave returns an empty result rather than throwing, which would
    // otherwise surface much later as a puzzling "no speech found".
    stderr.writeln(
      'Could not read ${input.path}.\n'
      'It must be a mono 16-bit PCM .wav — not .m4a, .mp3, or stereo, which is\n'
      'what phone recorders and Windows Voice Recorder usually produce.\n\n'
      'Convert with any of:\n'
      '  ffmpeg -i in.m4a -ac 1 -ar 16000 -c:a pcm_s16le out.wav\n'
      '  Audacity: Tracks > Mix > Stereo to Mono, then Export as WAV\n'
      '  online-audio-converter.com (pick WAV, mono)',
    );
    exitCode = 1;
    return;
  }

  final seconds = wave.samples.length / wave.sampleRate;
  stdout.writeln(
    '${input.path}: ${seconds.toStringAsFixed(2)}s '
    '@ ${wave.sampleRate} Hz',
  );
  stdout.writeln('${setup.language.label} — ${setup.activeSttModel}\n');

  final audio = resample(wave.samples, wave.sampleRate, kSampleRate);
  final stt = await setup.buildStt();

  if (args.flag('whole')) {
    final at = DateTime.now();
    final text = await stt.transcribe(audio);
    stdout.writeln('[whole file, ${_ms(at)}] $text');
    await stt.dispose();
    return;
  }

  final vad = SherpaVadEngine(model: '${setup.modelsDir}/silero_vad.onnx');
  // Trailing silence so the VAD closes the final segment.
  final padded = _concat([audio, Float32List(kSampleRate)]);

  // Corrections are applied to each utterance as it comes out, before the
  // paragraphs are built — so a name is already right when the cleanup pass
  // reads it, rather than being something that pass has to guess at.
  final vocabulary = await Vocabulary.load(
    args.option('vocabulary') ?? '${setup.modelsDir}/vocabulary.json',
  );
  if (!vocabulary.isEmpty) {
    stderr.writeln('${vocabulary.entries.length} vocabulary corrections');
  }

  final paragraphGap = Duration(
    milliseconds: (double.parse(args.option('gap')!) * 1000).round(),
  );
  final lines = <_Line>[];

  var n = 0;
  final started = DateTime.now();
  await for (final event in vad.process(_frames(padded))) {
    if (event case SpeechEnded(:final samples)) {
      final at = DateTime.now();
      final text = vocabulary.apply((await stt.transcribe(samples)).trim());
      n++;
      if (text.isEmpty) continue;

      final start = event.startAt();
      lines.add(_Line(start, samples.length / kSampleRate, text));

      if (args.option('out') == null) {
        stdout.writeln(
          '[$n] ${(samples.length / kSampleRate).toStringAsFixed(2)}s, ${_ms(at)}: $text',
        );
      } else if (n % 25 == 0) {
        // A long recording is minutes of silence otherwise; report progress
        // against the audio, which is the only honest measure of how far in
        // this is.
        stderr.writeln(
          '  ${_clock(start)} / ${_clock(Duration(seconds: seconds.round()))} '
          '· $n segments',
        );
      }
    }
  }
  if (n == 0) stderr.writeln('VAD found no speech — is the recording silent?');

  if (args.option('out') case final path?) {
    var paragraphs = _paragraphs(lines, paragraphGap);

    if (args.flag('polish') && paragraphs.isNotEmpty) {
      final llm = buildLlm(llmConfigFromEnvironment());
      stderr.writeln('\nTidying ${paragraphs.length} paragraphs…');
      var kept = 0;
      paragraphs = await _polish(
        llm,
        paragraphs,
        onProgress: (done, changed) {
          kept = changed;
          if (done % 5 == 0) stderr.writeln('  $done/${paragraphs.length}');
        },
      );
      stderr.writeln('  $kept of ${paragraphs.length} rewritten');
      await llm.dispose();
    }

    final file = File(path);
    await file.writeAsString(
      _markdown(
        paragraphs,
        polished: args.flag('polish'),
        title: args.option('title') ?? _titleFrom(input.path),
        source: input.path,
        duration: Duration(seconds: seconds.round()),
        model: setup.activeSttModel,
        took: DateTime.now().difference(started),
      ),
    );
    stderr.writeln('\nWrote ${file.path} — ${lines.length} segments');
  }

  await stt.dispose();
  await vad.dispose();
}

/// One recognised utterance, with where it sits in the recording.
class _Line {
  _Line(this.start, this.seconds, this.text);
  final Duration start;
  final double seconds;
  final String text;
}

/// A paragraph of the transcript, and where it starts.
class _Paragraph {
  _Paragraph(this.start, this.text);
  final Duration start;
  String text;
}

/// Groups utterances into paragraphs.
///
/// On the silence between them, and on a length cap: someone talking steadily
/// never leaves a long enough gap, and without the cap a twenty minute talk
/// comes out as one unreadable block.
List<_Paragraph> _paragraphs(List<_Line> lines, Duration gap) {
  const maxChars = 700;
  final out = <_Paragraph>[];
  if (lines.isEmpty) return out;

  var current = <String>[];
  var chars = 0;
  var start = lines.first.start;
  var previousEnd = lines.first.start;

  void flush() {
    if (current.isEmpty) return;
    out.add(_Paragraph(start, current.join(' ')));
    current = [];
    chars = 0;
  }

  for (final line in lines) {
    final silence = line.start - previousEnd;
    if (current.isNotEmpty &&
        (silence >= gap || chars + line.text.length > maxChars)) {
      flush();
    }
    if (current.isEmpty) start = line.start;
    current.add(line.text);
    chars += line.text.length + 1;
    previousEnd =
        line.start + Duration(milliseconds: (line.seconds * 1000).round());
  }
  flush();
  return out;
}

/// What the model is told to do with each paragraph.
///
/// Adapted from the dictation prompt in altic-dev/FluidVoice (MIT), which
/// solves the same problem from the other end: a recogniser produces the right
/// words in the wrong shape. The additions are for transcription rather than
/// dictation — someone else's words are being tidied, so nothing may be
/// invented and nothing may be summarised away.
const _polishPrompt =
    'You clean up raw speech-to-text output. You never answer it and you never '
    'add to it.\n'
    '\n'
    'Rules:\n'
    '1. Fix sentence boundaries. The recogniser puts full stops mid-thought; '
    'join and split so sentences follow the meaning.\n'
    '2. Fix capitalisation and punctuation.\n'
    '3. Remove filler words and false starts: um, uh, you know, I mean, '
    'repeated words, restarts.\n'
    '4. Keep every fact, name, number and opinion exactly as spoken. Do not '
    'summarise, do not shorten, do not improve the argument.\n'
    '5. Correct a word only when it is plainly a mis-hearing of a common term. '
    'If unsure, leave it alone.\n'
    '6. Write spoken numbers as digits: thirty minutes -> 30 minutes, five '
    'thirty -> 5:30, twelve fifty -> 12.50. Leave numbers that read better as '
    'words alone: "one of the largest".\n'
    '7. Output only the cleaned text. No preamble, no commentary, no quotes '
    'around it.';

/// Runs each paragraph through the model.
///
/// A paragraph at a time rather than the whole transcript: it bounds the
/// context, keeps timestamps attached, and means one bad response spoils one
/// paragraph instead of the document.
///
/// A reply that comes back empty, or much longer or shorter than the input, is
/// discarded in favour of the original. That is the shape of a refusal, a
/// summary or a hallucination, and the raw text is the safer of the two — this
/// is someone's actual words, and losing them is worse than leaving them
/// rough.
Future<List<_Paragraph>> _polish(
  LlmEngine llm,
  List<_Paragraph> paragraphs, {
  void Function(int done, int changed)? onProgress,
}) async {
  var changed = 0;
  for (var i = 0; i < paragraphs.length; i++) {
    final original = paragraphs[i].text;
    try {
      final buffer = StringBuffer();
      await for (final delta in llm.respond([
        const Message.system(_polishPrompt),
        Message.user(original),
      ])) {
        buffer.write(delta);
      }
      final cleaned = buffer.toString().trim();
      final ratio = cleaned.length / original.length;
      if (cleaned.isNotEmpty && ratio > 0.6 && ratio < 1.6) {
        paragraphs[i].text = cleaned;
        changed++;
      }
    } catch (_) {
      // Keep the raw paragraph. A transcript with a rough patch beats one with
      // a hole in it.
    }
    onProgress?.call(i + 1, changed);
  }
  return paragraphs;
}

/// Renders the transcript.
///
/// The timestamp on each paragraph is what makes the file useful — it is how
/// someone gets back to the audio.
String _markdown(
  List<_Paragraph> paragraphs, {
  required bool polished,
  required String title,
  required String source,
  required Duration duration,
  required String model,
  required Duration took,
}) {
  final out = StringBuffer()
    ..writeln('# $title')
    ..writeln()
    ..writeln('| | |')
    ..writeln('|---|---|')
    ..writeln('| Source | `${source.split(Platform.pathSeparator).last}` |')
    ..writeln('| Length | ${_clock(duration)} |')
    ..writeln('| Recognised by | $model |')
    ..writeln('| Paragraphs | ${paragraphs.length} |')
    ..writeln('| Transcribed in | ${_clock(took)} |')
    ..writeln();

  if (polished) {
    out
      ..writeln('> Machine transcription, tidied by a language model. The words')
      ..writeln('> are the speaker\'s; the punctuation and sentence breaks are')
      ..writeln('> a machine\'s reading of them. Check names, numbers and')
      ..writeln('> technical terms against the audio before quoting.')
      ..writeln();
  } else {
    out
      ..writeln('> Machine transcription. Names, numbers and technical terms')
      ..writeln('> are where it will be wrong; check those against the audio')
      ..writeln('> before quoting them.')
      ..writeln();
  }

  if (paragraphs.isEmpty) {
    out.writeln('_No speech was recognised._');
    return out.toString();
  }

  for (final p in paragraphs) {
    out
      ..writeln('**[${_clock(p.start)}]** ${p.text}')
      ..writeln();
  }
  return out.toString();
}

String _clock(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// A readable heading from the file name.
String _titleFrom(String path) {
  final name = path.split(Platform.pathSeparator).last;
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? name : name.substring(0, dot);
}

String _ms(DateTime since) =>
    '${DateTime.now().difference(since).inMilliseconds}ms';

Stream<AudioChunk> _frames(AudioChunk audio, {int size = 512}) async* {
  for (var i = 0; i < audio.length; i += size) {
    yield Float32List.sublistView(audio, i, (i + size).clamp(0, audio.length));
  }
}

AudioChunk _concat(List<AudioChunk> parts) {
  final out = Float32List(parts.fold(0, (n, p) => n + p.length));
  var offset = 0;
  for (final p in parts) {
    out.setAll(offset, p);
    offset += p.length;
  }
  return out;
}
