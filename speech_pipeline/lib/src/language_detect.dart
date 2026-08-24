import 'languages.dart';

/// What language a piece of text is in, and how sure we are.
class LanguageGuess {
  const LanguageGuess(this.language, this.confidence, this.why);

  final PipelineLanguage language;

  /// 0.0–1.0. Low means the evidence was thin, not that the guess is wrong —
  /// a two-word reply carries less signal than a sentence.
  final double confidence;

  /// What the decision rested on, for logging and for debugging a bad call.
  final String why;

  /// Enough evidence to act on. Below this a caller should keep whatever
  /// language it was already using rather than switch on a coin flip.
  bool get isConfident => confidence >= 0.6;

  @override
  String toString() =>
      '${language.code} (${(confidence * 100).round()}%, $why)';
}

/// Guesses the language of [text].
///
/// Script settles English against the rest. Nepali and Sanskrit both write in
/// Devanagari, so those are separated on function words and inflection — the
/// parts of a sentence that differ most and repeat most.
///
/// Deliberate limitation: Hindi and Marathi are also Devanagari and are not in
/// this pipeline's language set, so they will read as Nepali. Detection can
/// only choose among languages the pipeline can actually speak.
LanguageGuess detectLanguage(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) {
    return const LanguageGuess(PipelineLanguage.english, 0, 'empty');
  }

  var devanagari = 0;
  var latin = 0;
  for (final r in trimmed.runes) {
    if (r >= 0x0900 && r <= 0x097F) {
      devanagari++;
    } else if ((r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A)) {
      latin++;
    }
  }

  final letters = devanagari + latin;
  if (letters == 0) {
    return const LanguageGuess(PipelineLanguage.english, 0, 'no letters');
  }

  final devanagariShare = devanagari / letters;
  if (devanagariShare < 0.2) {
    // Confidence grows with how much text agreed; one Latin word proves little.
    return LanguageGuess(
      PipelineLanguage.english,
      _sureness(latin, 12),
      'Latin script',
    );
  }

  return _devanagariLanguage(trimmed, devanagariShare);
}

/// Nepali against Sanskrit.
LanguageGuess _devanagariLanguage(String text, double devanagariShare) {
  final padded = ' ${text.replaceAll(RegExp(r'[।॥,!?"\n]'), ' ')} ';

  var nepali = 0;
  var sanskrit = 0;
  for (final w in _nepaliMarkers) {
    if (padded.contains(' $w ')) nepali += 2;
  }
  for (final w in _sanskritMarkers) {
    if (padded.contains(' $w ')) sanskrit += 2;
  }

  // Visarga is the single strongest signal: standard in Sanskrit, essentially
  // absent from written Nepali.
  final visarga = ':'.allMatches('').length + _count(text, 'ः');
  sanskrit += visarga * 3;

  // A word ending in म् — Sanskrit's accusative and neuter nominative — is a
  // shape Nepali words do not take.
  sanskrit += RegExp(r'म्(\s|$|।)').allMatches(padded).length * 3;

  for (final e in _nepaliSuffixes) {
    nepali += RegExp('$e(\\s|\$|।)').allMatches(padded).length;
  }

  if (nepali == 0 && sanskrit == 0) {
    // Devanagari with nothing to go on. Nepali is the safer default here: it
    // is the conversational language of the two, and Sanskrit text is usually
    // liturgical and full of the markers above.
    return LanguageGuess(
      PipelineLanguage.nepali,
      0.3,
      'Devanagari, no distinguishing markers',
    );
  }

  final total = nepali + sanskrit;
  final winner = sanskrit > nepali
      ? PipelineLanguage.sanskrit
      : PipelineLanguage.nepali;
  final margin = (sanskrit - nepali).abs() / total;

  // Both the lead and the amount of evidence matter: 2–0 is a thinner case
  // than 20–2 even though the margin is wider.
  final confidence =
      (0.45 + margin * 0.4 + _sureness(total, 14) * 0.25).clamp(0.0, 1.0) *
      (devanagariShare < 0.6 ? 0.8 : 1.0);

  return LanguageGuess(
    winner,
    confidence,
    'Devanagari markers $nepali ne / $sanskrit sa',
  );
}

int _count(String s, String needle) => needle.allMatches(s).length;

/// Approaches 1.0 as the evidence reaches [enough].
double _sureness(int seen, int enough) => seen >= enough ? 1.0 : seen / enough;

/// Nepali function words. Copulas, postpositions and pronouns — the words that
/// appear in almost every sentence and have no Sanskrit equivalent in form.
const _nepaliMarkers = <String>[
  'छ',
  'छन्',
  'छु',
  'छौं',
  'छिन्',
  'थियो',
  'थिए',
  'थिएन',
  'हो',
  'होइन',
  'हुन्',
  'हुन्छ',
  'भयो',
  'भएको',
  'गर्न',
  'गर्नु',
  'गर्छ',
  'गरेको',
  'भन्ने',
  'भनेर',
  'लाई',
  'बाट',
  'सँग',
  'माथि',
  'तपाईं',
  'तपाईंलाई',
  'हामी',
  'हाम्रो',
  'मेरो',
  'तिमी',
  'उनी',
  'पनि',
  'अनि',
  'तर',
  'किन',
  'कस्तो',
  'कुन',
  'कहाँ',
  'धेरै',
  'राम्रो',
  'सबैभन्दा',
  'धन्यवाद',
  'नमस्ते',
];

/// Nepali inflectional endings, counted per occurrence.
const _nepaliSuffixes = <String>['को', 'का', 'की', 'ले', 'मा'];

/// Sanskrit function words and verb forms.
const _sanskritMarkers = <String>[
  'अस्ति',
  'सन्ति',
  'अस्मि',
  'भवति',
  'भवन्ति',
  'आसीत्',
  'बभूव',
  'इति',
  'एव',
  'च',
  'वा',
  'तु',
  'हि',
  'अपि',
  'यत्',
  'तत्',
  'किम्',
  'सः',
  'सा',
  'ते',
  'अहम्',
  'त्वम्',
  'वयम्',
  'मम',
  'नमः',
  'ॐ',
  'श्री',
  'सर्वे',
  'भवन्तु',
  'शान्तिः',
  'स्वाहा',
];
