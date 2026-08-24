import 'package:speech_pipeline/speech_pipeline.dart';
import 'package:test/test.dart';

void main() {
  group('repairDevanagari', () {
    test('leaves clean Nepali alone', () {
      const text = 'काठमाडौं नेपालको राजधानी हो।';
      final r = repairDevanagari(text);
      expect(r.text, text);
      expect(r.clean, isTrue);
      expect(r.summary, 'clean Devanagari');
    });

    test('repairs the word Gemma actually produced', () {
      // Verbatim from Gemma 3 4B asked in Nepali for the tallest mountain:
      // "Everest" spelled half Devanagari, half Bengali.
      final r = repairDevanagari('एভারেস্ট नेपालको सबैभन्दा अग्लो हिमाल हो।');
      expect(r.text, 'एभारेस्ट नेपालको सबैभन्दा अग्लो हिमाल हो।');
      expect(r.transposed['Bengali'], 7);
      expect(r.foreign, isEmpty);
    });

    test('maps a whole Bengali word letter for letter', () {
      // ক খ গ → क ख ग
      final r = repairDevanagari('কখগ');
      expect(r.text, 'कखग');
    });

    test('handles the other northern siblings', () {
      expect(repairDevanagari('ਕਖਗ').text, 'कखग'); // Gurmukhi
      expect(repairDevanagari('કખગ').text, 'कखग'); // Gujarati
      expect(repairDevanagari('କଖଗ').text, 'कखग'); // Oriya
    });

    test('passes Latin, digits and punctuation through', () {
      const text = 'ChatGPT ले 2026 मा भन्यो, "नमस्ते!"';
      expect(repairDevanagari(text).text, text);
    });

    test('leaves southern scripts alone rather than inventing sounds', () {
      // Tamil has no aspirates or voiced stops, so an offset map would put
      // letters in the output that the model never wrote.
      final r = repairDevanagari('தமிழ் हो।');
      expect(r.text, contains('தமிழ'), reason: 'not silently transposed');
      expect(r.foreign, isNotEmpty);
      expect(r.transposed, isEmpty);
    });

    test('never drops characters it cannot map', () {
      // Mangled pronunciation is recoverable; a deleted clause is not.
      final r = repairDevanagari('తెలుగు');
      expect(r.text.runes.length, 'తెలుగు'.runes.length);
    });

    test('reports what it did', () {
      final r = repairDevanagari('এভারেস্ট');
      expect(r.changed, isTrue);
      expect(r.summary, contains('Bengali'));
    });
  });

  _cloneEngineLanguage();

  group('isDevanagariClean', () {
    test('accepts Devanagari, Latin and punctuation', () {
      expect(isDevanagariClean('नमस्ते, Nepal 2026!'), isTrue);
    });

    test('rejects any sibling Brahmic character', () {
      expect(isDevanagariClean('एভারেস্ট'), isFalse);
      expect(isDevanagariClean('தமிழ்'), isFalse);
    });
  });
}

void _cloneEngineLanguage() {
  group('CloneTtsEngine.engineLanguageFor', () {
    test('maps Nepali to the id OmniVoice actually accepts', () {
      // OmniVoice's table is ISO 639-3; passing 'ne' fails the whole turn with
      // "unsupported OmniVoice language 'ne'".
      expect(CloneTtsEngine.engineLanguageFor('ne'), 'npi');
    });

    test('leaves codes that already match alone', () {
      expect(CloneTtsEngine.engineLanguageFor('sa'), 'sa');
      expect(CloneTtsEngine.engineLanguageFor('en'), 'en');
    });

    test('passes unknown codes through for the engine to judge', () {
      expect(CloneTtsEngine.engineLanguageFor('bho'), 'bho');
      expect(CloneTtsEngine.engineLanguageFor(null), isNull);
    });
  });
}
