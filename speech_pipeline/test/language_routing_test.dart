import 'dart:typed_data';

import 'package:speech_pipeline/speech_pipeline.dart';
import 'package:test/test.dart';

/// Records what it was asked to say and at what rate it speaks.
class FakeVoice implements TtsEngine {
  FakeVoice(this.sampleRate, {this.samples = 480});

  @override
  final int sampleRate;
  final int samples;
  final List<String> spoken = [];
  bool disposed = false;

  @override
  Stream<AudioChunk> synthesize(String text) async* {
    spoken.add(text);
    yield Float32List(samples);
  }

  @override
  Future<void> dispose() async => disposed = true;
}

void main() {
  late FakeVoice english, nepali, sanskrit;
  late LanguageRoutingTtsEngine router;

  setUp(() {
    english = FakeVoice(24000);
    nepali = FakeVoice(22050);
    sanskrit = FakeVoice(24000);
    router = LanguageRoutingTtsEngine.over({
      PipelineLanguage.english: english,
      PipelineLanguage.nepali: nepali,
      PipelineLanguage.sanskrit: sanskrit,
    }, fallback: PipelineLanguage.english);
  });

  test('declares one rate, the highest of its voices', () {
    // Playback is configured once; a rate that changed mid-conversation would
    // desynchronise the player.
    expect(router.sampleRate, 24000);
  });

  test('resamples a voice that does not match the declared rate', () async {
    final out = await router
        .synthesize('नेपालको राजधानी काठमाडौं हो।')
        .toList();
    expect(nepali.spoken, isNotEmpty);
    // 480 samples at 22050 stretched to 24000.
    expect(out.single.length, closeTo(480 * 24000 / 22050, 2));
  });

  test('passes a matching voice through untouched', () async {
    final out = await router.synthesize('The capital is Kathmandu.').toList();
    expect(english.spoken, isNotEmpty);
    expect(out.single.length, 480);
  });

  test('sends each language to its own voice', () async {
    await router.synthesize('How are you today?').drain<void>();
    await router.synthesize('तपाईंलाई कस्तो छ?').drain<void>();
    await router.synthesize('सर्वे भवन्तु सुखिनः').drain<void>();

    expect(english.spoken.length, 1);
    expect(nepali.spoken.length, 1);
    expect(sanskrit.spoken.length, 1);
  });

  test(
    'answers a Nepali reply in the Nepali voice even when set to English',
    () async {
      // The bug this exists for: the reply's language is the model's choice, not
      // the configuration's.
      await router.synthesize('The capital is Kathmandu.').drain<void>();
      expect(router.current, PipelineLanguage.english);

      await router.synthesize('काठमाडौं नेपालको राजधानी हो।').drain<void>();
      expect(router.current, PipelineLanguage.nepali);
      expect(english.spoken.length, 1, reason: 'English voice not reused');
    },
  );

  test('stays put when the evidence is thin, rather than flickering', () async {
    await router.synthesize('तपाईंलाई कस्तो छ?').drain<void>();
    expect(router.current, PipelineLanguage.nepali);

    await router.synthesize('ok').drain<void>();
    expect(
      router.current,
      PipelineLanguage.nepali,
      reason: 'a two-word fragment must not flip the voice',
    );
    expect(nepali.spoken.length, 2);
  });

  test('reports a change once, not on every utterance', () async {
    final changes = <PipelineLanguage>[];
    router.onLanguageChanged = (lang, _) => changes.add(lang);

    await router.synthesize('तपाईंलाई कस्तो छ?').drain<void>();
    await router.synthesize('नेपालको राजधानी काठमाडौं हो।').drain<void>();
    await router.synthesize('How are you today?').drain<void>();

    expect(changes, [PipelineLanguage.nepali, PipelineLanguage.english]);
  });

  test('falls back when it has no voice for the detected language', () async {
    final limited = LanguageRoutingTtsEngine.over({
      PipelineLanguage.english: english,
    }, fallback: PipelineLanguage.english);
    await limited.synthesize('सर्वे भवन्तु सुखिनः').drain<void>();
    expect(
      english.spoken.length,
      1,
      reason: 'spoken by the only voice present',
    );
  });

  test('refuses a configuration that cannot work', () {
    expect(
      () => LanguageRoutingTtsEngine.over(
        const {},
        fallback: PipelineLanguage.english,
      ),
      throwsArgumentError,
    );
    expect(
      () => LanguageRoutingTtsEngine.over({
        PipelineLanguage.nepali: nepali,
      }, fallback: PipelineLanguage.english),
      throwsArgumentError,
      reason: 'a fallback with no voice would fail at the worst moment',
    );
  });

  test('disposes every voice it owns', () async {
    await router.dispose();
    expect([
      english.disposed,
      nepali.disposed,
      sanskrit.disposed,
    ], everyElement(isTrue));
  });
}
