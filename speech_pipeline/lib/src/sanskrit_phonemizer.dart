/// Devanagari → IPA for Sanskrit, targeting Kokoro's phoneme vocabulary.
///
/// Ported from EdgeSanskrit-TTS (`Hari7718/EdgeSanskrit-TTS`, MIT), whose
/// approach is to bypass espeak-ng entirely. That matters because espeak's
/// Hindi voice applies Hindi phonology to Devanagari: it deletes the inherent
/// schwa (*Rāma* → *Rām*), collapses anusvara to a generic nasal, and drops
/// visarga. All three are wrong for Sanskrit, and all three are handled here.
///
/// Output is IPA drawn from Kokoro's 177-token vocabulary, which already
/// carries every retroflex, aspirate and length marker Sanskrit needs.
library;

const _vowels = <String, String>{
  'अ': 'a',
  'आ': 'aː',
  'इ': 'i',
  'ई': 'iː',
  'उ': 'u',
  'ऊ': 'uː',
  'ऋ': 'ɾɪ',
  'ॠ': 'ɾiː',
  'ऌ': 'lɪ',
  'ए': 'e',
  'ऐ': 'aɪ',
  'ओ': 'o',
  'औ': 'aʊ',
};

/// Dependent vowel signs (matras), which replace a consonant's inherent 'a'.
const _vowelSigns = <String, String>{
  'ा': 'aː',
  'ि': 'i',
  'ी': 'iː',
  'ु': 'u',
  'ू': 'uː',
  'ृ': 'ɾɪ',
  'ॄ': 'ɾiː',
  'ॢ': 'lɪ',
  'े': 'e',
  'ै': 'aɪ',
  'ो': 'o',
  'ौ': 'aʊ',
};

const _consonants = <String, String>{
  'क': 'k', 'ख': 'kʰ', 'ग': 'ɡ', 'घ': 'ɡʰ', 'ङ': 'ŋ',
  'च': 'tʃ', 'छ': 'tʃʰ', 'ज': 'dʒ', 'झ': 'dʒʰ', 'ञ': 'ɲ',
  'ट': 'ʈ', 'ठ': 'ʈʰ', 'ड': 'ɖ', 'ढ': 'ɖʰ', 'ण': 'ɳ',
  'त': 't', 'थ': 'tʰ', 'द': 'd', 'ध': 'dʰ', 'न': 'n',
  'प': 'p', 'फ': 'pʰ', 'ब': 'b', 'भ': 'bʰ', 'म': 'm',
  'य': 'j', 'र': 'ɾ', 'ल': 'l', 'व': 'v',
  'श': 'ʃ', 'ष': 'ʂ', 'स': 's', 'ह': 'h',
  'ळ': 'ɭ',
};

const _virama = '्';
const _anusvara = 'ं';
const _visarga = 'ः';
const _avagraha = 'ऽ';

/// Consonant classes, each with the nasal that anusvara assimilates to.
const _vargas = <(String, String)>[
  ('कखगघङ', 'ŋ'), // velar
  ('चछजझञ', 'ɲ'), // palatal
  ('टठडढण', 'ɳ'), // retroflex
  ('तथदधन', 'n'), // dental
  ('पफबभम', 'm'), // labial
];

const _boundaries = {' ', '\n', '\t', '।', '॥', ',', '.'};
const _passThroughPunctuation = {',', ';', '.', '!', '?'};

/// Converts Devanagari Sanskrit to a Kokoro-compatible IPA string.
///
/// The inherent vowel is always pronounced unless a virama or matra says
/// otherwise — no schwa deletion.
String devanagariToIpa(String text) {
  final input = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  final out = StringBuffer();

  // Visarga echoes the preceding vowel, so it has to be tracked across chars.
  var lastVowel = 'a';
  var i = 0;

  while (i < input.length) {
    final char = input[i];

    if (_vowels[char] case final vowel?) {
      out.write(vowel);
      lastVowel = vowel;
      i++;
      continue;
    }

    if (_consonants[char] case final consonant?) {
      final next = i + 1 < input.length ? input[i + 1] : null;
      final sign = next == null ? null : _vowelSigns[next];

      if (next == _virama) {
        out.write(consonant); // bare consonant, no inherent vowel
        i += 2;
      } else if (sign != null) {
        out.write('$consonant$sign');
        lastVowel = sign;
        i += 2;
      } else {
        out.write('${consonant}a'); // inherent short 'a'
        lastVowel = 'a';
        i++;
      }
      continue;
    }

    switch (char) {
      case _anusvara:
        out.write(_homorganicNasal(input, i));
      case _visarga:
        out.write(_visargaEcho(lastVowel));
      case _avagraha:
        // Avagraha marks an elided initial 'a'; lengthening the preceding
        // vowel is the reference implementation's approximation of that.
        out.write('ː');
      case ' ' || '\n' || '\t':
        out.write(' ');
      case '।' || '॥':
        out.write('.'); // dandas become periods so the model pauses
      default:
        if (_passThroughPunctuation.contains(char)) out.write(char);
      // Anything else (digits, brackets) is dropped.
    }
    i++;
  }

  return out.toString().replaceAll(RegExp(r' +'), ' ');
}

/// Anusvara assimilates to the class of the *following* consonant.
String _homorganicNasal(String text, int index) {
  for (var i = index + 1; i < text.length; i++) {
    final char = text[i];
    if (_consonants.containsKey(char)) {
      for (final (chars, nasal) in _vargas) {
        if (chars.contains(char)) return nasal;
      }
      break;
    }
    if (_boundaries.contains(char)) break;
  }
  return 'm';
}

/// Visarga is realised as /h/ plus an echo of the preceding vowel.
String _visargaEcho(String previousVowel) {
  final core = previousVowel.replaceAll('ː', '').trim();
  if (core.isEmpty) return 'ha';
  for (final vowel in const ['a', 'i', 'u', 'e', 'o']) {
    if (core.contains(vowel)) return 'h$vowel';
  }
  return 'ha';
}
