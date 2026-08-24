import 'package:speech_pipeline/speech_pipeline.dart';
import 'package:test/test.dart';

void main() {
  PipelineLanguage of(String s) => detectLanguage(s).language;

  group('English', () {
    test('plain sentences', () {
      expect(
        of('The capital of Nepal is Kathmandu.'),
        PipelineLanguage.english,
      );
      expect(of('How are you doing today?'), PipelineLanguage.english);
    });

    test('is confident once there is a sentence to go on', () {
      expect(
        detectLanguage('What is the tallest mountain?').isConfident,
        isTrue,
      );
    });

    test('stays unconfident on a fragment, rather than guessing loudly', () {
      // A caller should keep its current language rather than switch on this.
      expect(detectLanguage('ok').isConfident, isFalse);
    });
  });

  group('Nepali', () {
    test('recognises real replies produced by the pipeline', () {
      // Verbatim Gemma 3 4B output captured through this pipeline.
      expect(of('काठमाडौं नेपालको राजधानी हो।'), PipelineLanguage.nepali);
      expect(of('म एकदमै राम्रो छु, धन्यवाद!'), PipelineLanguage.nepali);
      expect(
        of(
          'नमस्ते! नेपालको राजधानी काठमाडौं हो। '
          'मलाई आशा छ तपाईंलाई यो जानकारीले मदत गर्छ।',
        ),
        PipelineLanguage.nepali,
      );
    });

    test('recognises a spoken question', () {
      expect(
        of('नेपालको सबैभन्दा अग्लो हिमाल कुन हो?'),
        PipelineLanguage.nepali,
      );
      expect(of('तपाईंलाई कस्तो छ?'), PipelineLanguage.nepali);
    });
  });

  group('Sanskrit', () {
    test('separates it from Nepali despite the shared script', () {
      expect(of('भारतस्य राजधानी नवदेहली अस्ति।'), PipelineLanguage.sanskrit);
      expect(of('सर्वे भवन्तु सुखिनः'), PipelineLanguage.sanskrit);
      expect(of('ॐ नमः शिवाय'), PipelineLanguage.sanskrit);
    });

    test('visarga alone is strong evidence', () {
      final guess = detectLanguage('शान्तिः शान्तिः शान्तिः');
      expect(guess.language, PipelineLanguage.sanskrit);
      expect(guess.isConfident, isTrue);
    });
  });

  group('honesty about the edges', () {
    test(
      'bare Devanagari with no markers is a low-confidence Nepali guess',
      () {
        final guess = detectLanguage('कखग');
        expect(guess.isConfident, isFalse);
        expect(guess.why, contains('no distinguishing markers'));
      },
    );

    test('empty and symbol-only text never claim confidence', () {
      expect(detectLanguage('').confidence, 0);
      expect(detectLanguage('!!! 123 ???').confidence, 0);
    });

    test('a mixed sentence is scored, not rejected', () {
      // Nepali replies routinely carry Latin product names and numerals.
      expect(
        of('ChatGPT ले 2026 मा भन्यो, नेपाल राम्रो छ।'),
        PipelineLanguage.nepali,
      );
    });

    test('reports its reasoning', () {
      expect(detectLanguage('Hello there').why, 'Latin script');
      expect(detectLanguage('अस्ति च').why, contains('markers'));
    });
  });
}
