import 'package:speech_pipeline/speech_pipeline.dart';
import 'package:test/test.dart';

void main() {
  group('matches the EdgeSanskrit reference implementation', () {
    // Ground truth captured by running the upstream Python phonemizer.
    const cases = {
      'नमः शिवाय': 'namaha ʃivaːja',
      'धर्मक्षेत्रे कुरुक्षेत्रे': 'dʰaɾmakʂetɾe kuɾukʂetɾe',
      'रामः गच्छति': 'ɾaːmaha ɡatʃtʃʰati',
      'सच्चिदानन्द': 'satʃtʃidaːnanda',
      'श्रीमद्भगवद्गीता': 'ʃɾiːmadbʰaɡavadɡiːtaː',
    };

    cases.forEach((devanagari, expected) {
      test(devanagari, () {
        expect(devanagariToIpa(devanagari), expected);
      });
    });
  });

  test('keeps the inherent vowel — no Hindi schwa deletion', () {
    // The whole point: Hindi phonology would give "ɾaːm".
    expect(devanagariToIpa('राम'), 'ɾaːma');
  });

  test('virama suppresses the inherent vowel', () {
    expect(devanagariToIpa('राम्'), 'ɾaːm');
  });

  test('anusvara assimilates to the following consonant class', () {
    expect(devanagariToIpa('अंक'), startsWith('aŋ')); // velar
    expect(devanagariToIpa('अंच'), startsWith('aɲ')); // palatal
    expect(devanagariToIpa('अंट'), startsWith('aɳ')); // retroflex
    expect(devanagariToIpa('अंत'), startsWith('an')); // dental
    expect(devanagariToIpa('अंप'), startsWith('am')); // labial
  });

  test('anusvara falls back to labial at a boundary', () {
    expect(devanagariToIpa('अं'), 'am');
  });

  test('visarga echoes the preceding vowel', () {
    expect(devanagariToIpa('रामः'), endsWith('ha'));
    expect(devanagariToIpa('हरिः'), endsWith('hi'));
    expect(devanagariToIpa('गुरुः'), endsWith('hu'));
  });

  test('dandas become sentence breaks the model can pause on', () {
    expect(devanagariToIpa('राम। शिव॥'), 'ɾaːma. ʃiva.');
  });

  test('collapses whitespace and drops unmappable characters', () {
    expect(devanagariToIpa('  राम   ५६ (शिव)  '), 'ɾaːma ʃiva');
  });

  test('produces only phonemes Kokoro can tokenise', () {
    // Every symbol emitted must exist in Kokoro's 177-token vocabulary,
    // otherwise synthesis silently drops it.
    const kokoroSymbols =
        'abdefhijklmnoprstuvzɐɑɒɔəɛɜɡɪɹɾʃʊʋʌʒʔʈɖɳʂɲŋɭɜː'
        'ʰɚɝθðŋæaʊaɪeɪoʊ .,;:!?';
    const samples = [
      'नमः शिवाय',
      'श्रीमद्भगवद्गीता',
      'धर्मक्षेत्रे कुरुक्षेत्रे',
      'अहं ब्रह्मास्मि',
    ];

    for (final sample in samples) {
      final ipa = devanagariToIpa(sample);
      final unknown = ipa.split('').where((c) => !kokoroSymbols.contains(c));
      expect(unknown, isEmpty, reason: 'unmapped symbols in "$ipa"');
    }
  });
}
