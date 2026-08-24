import 'dart:async';
import 'dart:typed_data';

import 'package:speech_pipeline/speech_pipeline.dart';
import 'package:test/test.dart';

/// Emits scripted VAD events; ignores the audio stream entirely.
class FakeVad implements VadEngine {
  final _events = StreamController<VadEvent>();

  void emit(VadEvent e) => _events.add(e);

  @override
  Stream<VadEvent> process(Stream<AudioChunk> audio) => _events.stream;

  @override
  Future<void> dispose() async => _events.close();
}

class FakeStt implements SttEngine {
  FakeStt(this.text);
  final String text;

  @override
  Future<String> transcribe(AudioChunk samples) async => text;

  @override
  Future<void> dispose() async {}
}

/// Emits [deltas] one at a time, pausing between each so a test can interrupt
/// the turn partway through.
class FakeLlm implements LlmEngine {
  FakeLlm(this.deltas, {this.gap = Duration.zero});
  final List<String> deltas;
  final Duration gap;
  final List<List<Message>> prompts = [];

  @override
  Stream<String> respond(List<Message> history) async* {
    prompts.add(List.of(history));
    for (final d in deltas) {
      if (gap > Duration.zero) await Future<void>.delayed(gap);
      yield d;
    }
  }

  @override
  Future<void> dispose() async {}
}

class FakeTts implements TtsEngine {
  final List<String> spoken = [];

  @override
  int get sampleRate => 24000;

  @override
  Stream<AudioChunk> synthesize(String text) async* {
    spoken.add(text);
    yield Float32List.fromList([0.0, 0.1, 0.2]);
  }

  @override
  Future<void> dispose() async {}
}

SpeechPipeline buildPipeline({
  required FakeVad vad,
  required FakeStt stt,
  required FakeLlm llm,
  required FakeTts tts,
}) =>
    SpeechPipeline(
      vad: vad,
      stt: stt,
      llm: llm,
      tts: tts,
      systemPrompt: 'test',
    );

void main() {
  test('splits a reply into speakable sentences', () async {
    final vad = FakeVad();
    final tts = FakeTts();
    final pipeline = buildPipeline(
      vad: vad,
      stt: FakeStt('what is the weather'),
      llm: FakeLlm(['It is ', 'sunny today. ', 'Bring ', 'sunglasses.']),
      tts: tts,
    );

    final events = <PipelineEvent>[];
    final done = pipeline.run(const Stream.empty()).listen(events.add);

    vad.emit(SpeechEnded(Float32List(160)));
    await pumpUntil(() => events.whereType<TurnComplete>().isNotEmpty);
    await done.cancel();

    expect(tts.spoken, ['It is sunny today.', 'Bring sunglasses.']);
    expect(
      events.whereType<UserTranscript>().single.text,
      'what is the weather',
    );
    expect(events.whereType<AssistantAudio>(), hasLength(2));
  });

  test('does not split on a decimal point', () async {
    final vad = FakeVad();
    final tts = FakeTts();
    final pipeline = buildPipeline(
      vad: vad,
      stt: FakeStt('how tall'),
      llm: FakeLlm(['About 1.8 metres tall.']),
      tts: tts,
    );

    final events = <PipelineEvent>[];
    final done = pipeline.run(const Stream.empty()).listen(events.add);

    vad.emit(SpeechEnded(Float32List(160)));
    await pumpUntil(() => events.whereType<TurnComplete>().isNotEmpty);
    await done.cancel();

    expect(tts.spoken, ['About 1.8 metres tall.']);
  });

  test('barge-in abandons the turn mid-reply', () async {
    final vad = FakeVad();
    final tts = FakeTts();
    final pipeline = buildPipeline(
      vad: vad,
      stt: FakeStt('tell me a long story'),
      llm: FakeLlm(
        ['One. ', 'Two. ', 'Three. ', 'Four. ', 'Five.'],
        gap: const Duration(milliseconds: 20),
      ),
      tts: tts,
    );

    final events = <PipelineEvent>[];
    final done = pipeline.run(const Stream.empty()).listen(events.add);

    vad.emit(SpeechEnded(Float32List(160)));
    await pumpUntil(() => tts.spoken.isNotEmpty);
    vad.emit(const SpeechStarted());
    await pumpUntil(() => events.whereType<Interrupted>().isNotEmpty);

    final spokenAtInterrupt = tts.spoken.length;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await done.cancel();

    expect(spokenAtInterrupt, lessThan(5));
    expect(tts.spoken, hasLength(spokenAtInterrupt),
        reason: 'generation must stop once the turn is cancelled');
    expect(events.whereType<TurnComplete>(), isEmpty);
  });

  test('carries conversation history into the next prompt', () async {
    final vad = FakeVad();
    final llm = FakeLlm(['Hello there.']);
    final pipeline = buildPipeline(
      vad: vad,
      stt: FakeStt('hi'),
      llm: llm,
      tts: FakeTts(),
    );

    final events = <PipelineEvent>[];
    final done = pipeline.run(const Stream.empty()).listen(events.add);

    vad.emit(SpeechEnded(Float32List(160)));
    await pumpUntil(() => events.whereType<TurnComplete>().isNotEmpty);
    vad.emit(SpeechEnded(Float32List(160)));
    await pumpUntil(() => llm.prompts.length == 2);
    await done.cancel();

    expect(llm.prompts.last.map((m) => m.role),
        ['system', 'user', 'assistant', 'user']);
    expect(llm.prompts.last[2].content, 'Hello there.');
  });
}

/// Yields to the event loop until [condition] holds, so tests don't depend on
/// a fixed number of microtask turns.
Future<void> pumpUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('pumpUntil timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
