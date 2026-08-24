import 'dart:async';

import 'engines.dart';

sealed class PipelineEvent {
  const PipelineEvent();
}

/// The user started talking. Emitted before their utterance is complete.
final class UserSpeaking extends PipelineEvent {
  const UserSpeaking();
}

/// The user stopped talking; recognition has not run yet.
///
/// This is the moment they begin waiting, so it is the honest zero for any
/// latency measurement — and the cue for a UI to show that it is thinking.
final class UserFinishedSpeaking extends PipelineEvent {
  const UserFinishedSpeaking();
}

final class UserTranscript extends PipelineEvent {
  const UserTranscript(this.text);
  final String text;
}

/// A token delta from the LLM, for live captions.
final class AssistantDelta extends PipelineEvent {
  const AssistantDelta(this.text);
  final String text;
}

/// Synthesised audio at [SpeechPipeline.outputSampleRate].
final class AssistantAudio extends PipelineEvent {
  const AssistantAudio(this.samples);
  final AudioChunk samples;
}

final class TurnComplete extends PipelineEvent {
  const TurnComplete(this.text);
  final String text;
}

/// The user talked over the assistant; the turn was abandoned.
final class Interrupted extends PipelineEvent {
  const Interrupted();
}

final class PipelineError extends PipelineEvent {
  const PipelineError(this.error, this.stackTrace);
  final Object error;
  final StackTrace stackTrace;
}

/// Wires VAD → STT → LLM → TTS into a conversation loop.
///
/// Mirrors the staged design of the Python reference, but the stage boundaries
/// are streams rather than thread queues: downstream backpressure (a slow
/// playback device) propagates back to token generation for free.
class SpeechPipeline {
  SpeechPipeline({
    required VadEngine vad,
    required SttEngine stt,
    required LlmEngine llm,
    required TtsEngine tts,
    String systemPrompt = _defaultSystemPrompt,
    this.maxHistoryTurns = 12,
  }) : _vad = vad,
       _stt = stt,
       _llm = llm,
       _tts = tts,
       _systemPrompt = systemPrompt;

  static const _defaultSystemPrompt =
      'You are a voice assistant. Your replies are spoken aloud, so keep them '
      'short and conversational — usually one or two sentences. Do not use '
      'markdown, lists, or emoji.';

  final VadEngine _vad;
  final SttEngine _stt;
  final LlmEngine _llm;
  final TtsEngine _tts;
  final String _systemPrompt;

  /// Sample rate of [AssistantAudio], set by the loaded voice. Usually differs
  /// from the 16 kHz input rate.
  int get outputSampleRate => _tts.sampleRate;

  /// Conversation turns kept in context, excluding the system prompt.
  final int maxHistoryTurns;

  final List<Message> _history = [];
  _Turn? _active;

  /// Drive the pipeline from a continuous 16 kHz mono mic stream.
  Stream<PipelineEvent> run(Stream<AudioChunk> mic) {
    late StreamController<PipelineEvent> out;
    StreamSubscription<VadEvent>? sub;

    out = StreamController<PipelineEvent>(
      onListen: () {
        sub = _vad
            .process(mic)
            .listen(
              (event) => _onVadEvent(event, out),
              onError: (Object e, StackTrace s) => out.add(PipelineError(e, s)),
              // The last utterance is still being answered when the mic stream
              // ends; closing here would drop its reply on the floor.
              onDone: () async {
                await _active?.finished;
                await out.close();
              },
            );
      },
      onCancel: () async {
        _active?.cancel();
        await sub?.cancel();
      },
    );

    return out.stream;
  }

  void _onVadEvent(VadEvent event, StreamController<PipelineEvent> out) {
    switch (event) {
      case SpeechStarted():
        out.add(const UserSpeaking());
        // Barge-in: talking over the assistant abandons its turn.
        if (_active case final turn? when !turn.done) {
          turn.cancel();
          out.add(const Interrupted());
        }

      case SpeechEnded(:final samples):
        out.add(const UserFinishedSpeaking());
        final turn = _Turn();
        _active = turn;
        unawaited(_runTurn(samples, turn, out));
    }
  }

  Future<void> _runTurn(
    AudioChunk samples,
    _Turn turn,
    StreamController<PipelineEvent> out,
  ) async {
    try {
      final transcript = await _stt.transcribe(samples);
      if (turn.cancelled || transcript.isEmpty) return;
      out.add(UserTranscript(transcript));

      _history.add(Message.user(transcript));
      _trimHistory();

      final reply = StringBuffer();
      final prompt = [Message.system(_systemPrompt), ..._history];

      await for (final sentence in _sentences(
        _llm.respond(prompt),
        turn,
        out,
      )) {
        if (turn.cancelled) break;
        await for (final chunk in _tts.synthesize(sentence)) {
          if (turn.cancelled) break;
          out.add(AssistantAudio(chunk));
        }
        reply.write(reply.isEmpty ? sentence : ' $sentence');
      }

      if (reply.isNotEmpty) {
        _history.add(Message.assistant(reply.toString()));
        if (!turn.cancelled) out.add(TurnComplete(reply.toString()));
      }
    } catch (e, s) {
      if (!turn.cancelled) out.add(PipelineError(e, s));
    } finally {
      turn.done = true;
    }
  }

  /// Regroups token deltas into speakable sentences.
  ///
  /// The first sentence is flushed on a shorter boundary than later ones —
  /// time-to-first-audio dominates how responsive the assistant feels, and a
  /// clause is close enough to a sentence to sound natural at the start.
  Stream<String> _sentences(
    Stream<String> deltas,
    _Turn turn,
    StreamController<PipelineEvent> out,
  ) async* {
    final buffer = StringBuffer();
    var isFirst = true;

    await for (final delta in deltas) {
      if (turn.cancelled) return;
      out.add(AssistantDelta(delta));
      buffer.write(delta);

      var text = buffer.toString();
      var cut = _breakPoint(text, allowClause: isFirst);
      while (cut > 0) {
        final sentence = text.substring(0, cut).trim();
        if (sentence.isNotEmpty) {
          yield sentence;
          isFirst = false;
        }
        text = text.substring(cut);
        cut = _breakPoint(text, allowClause: isFirst);
      }

      buffer
        ..clear()
        ..write(text);
    }

    final tail = buffer.toString().trim();
    if (tail.isNotEmpty && !turn.cancelled) yield tail;
  }

  static const _terminators = {'.', '!', '?', '\n', '。', '！', '？'};
  static const _clauseBreaks = {',', ';', ':', '，', '；'};

  /// Index just past the first usable break, or 0 if there isn't one yet.
  static int _breakPoint(String text, {required bool allowClause}) {
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (_terminators.contains(ch)) {
        // Ignore decimal points and abbreviations: require a following space.
        if (ch == '.' && i + 1 < text.length && text[i + 1] != ' ') continue;
        if (i >= 2) return i + 1;
      }
      // Only worth cutting early if enough words are already buffered.
      if (allowClause && _clauseBreaks.contains(ch) && i >= 12) return i + 1;
    }
    return 0;
  }

  void _trimHistory() {
    final excess = _history.length - maxHistoryTurns;
    if (excess > 0) _history.removeRange(0, excess);
  }

  void clearHistory() => _history.clear();

  Future<void> dispose() async {
    _active?.cancel();
    await Future.wait([
      _vad.dispose(),
      _stt.dispose(),
      _llm.dispose(),
      _tts.dispose(),
    ]);
  }
}

class _Turn {
  final _completion = Completer<void>();

  bool cancelled = false;
  bool _done = false;

  bool get done => _done;

  set done(bool value) {
    _done = value;
    if (value && !_completion.isCompleted) _completion.complete();
  }

  Future<void> get finished => _completion.future;

  void cancel() => cancelled = true;
}
