/// Repairs mixed-script text before it reaches a synthesiser.
///
/// Multilingual LLMs leak sibling Indic scripts into Devanagari output. Gemma 3
/// 4B, asked in Nepali for the tallest mountain, answers `एভারেস্ট` — the word
/// "Everest" spelled half in Devanagari and half in Bengali, inside an
/// otherwise clean Nepali sentence. Prompting does not reliably stop it:
/// demanding Devanagari suppresses the mixing only by making the model evade
/// the question.
///
/// This is repairable rather than merely detectable. Unicode lays the Brahmic
/// blocks out in parallel — Devanagari क is U+0915, Bengali ক is U+0995 — so
/// the sibling letter sits a fixed offset away from its Devanagari counterpart.
/// `एভারেস্ট` shifted down by 0x80 is `एभारेस्ट`, which is the right word.
///
/// Only the northern scripts are mapped. They share Devanagari's phonemic
/// inventory, so the transposition is faithful. Tamil and its neighbours do
/// not — Tamil has no aspirate or voiced-stop letters — and mapping those by
/// offset would invent sounds the model never wrote.
library;

import 'engines.dart';

/// Devanagari, and the sibling blocks a fixed offset above it.
const _devanagariBase = 0x0900;

const _siblings = <String, int>{
  'Bengali': 0x0980,
  'Gurmukhi': 0x0A00,
  'Gujarati': 0x0A80,
  'Oriya': 0x0B00,
};

/// Which offsets within each block have a true Devanagari counterpart.
///
/// Derived from the Unicode names: an offset is set only where the sibling's
/// name matches Devanagari's at the same position, so `BENGALI LETTER BHA` maps
/// to `DEVANAGARI LETTER BHA` but `BENGALI ANJI` — whose neighbour is an
/// unrelated candrabindu — does not. Bit N covers `base + N`.
final _masks = <String, BigInt>{
  'Bengali': BigInt.parse('0000ffcfa000399ff3c5fdfffff99fee', radix: 16),
  'Gurmukhi': BigInt.parse('0000ffc04e003107d36dfdfffff107e8', radix: 16),
  'Gujarati': BigInt.parse('0201ffcf00013bbff3edfdfffff99fee', radix: 16),
  'Oriya': BigInt.parse('0000ffcfa000399ff3edfdfffff99fee', radix: 16),
};

/// What [repairDevanagari] changed, and what it could not.
class ScriptRepair {
  const ScriptRepair(this.text, this.transposed, this.foreign);

  final String text;

  /// Sibling-script characters moved into Devanagari, by script name.
  final Map<String, int> transposed;

  /// Characters left alone because no faithful mapping exists — a South Indian
  /// script, or a symbol with no Devanagari counterpart. Reported rather than
  /// dropped: silently deleting part of an answer is worse than mispronouncing
  /// it, and the caller may want to log or re-ask.
  final String foreign;

  bool get changed => transposed.isNotEmpty;
  bool get clean => transposed.isEmpty && foreign.isEmpty;

  String get summary {
    if (clean) return 'clean Devanagari';
    final parts = [
      for (final e in transposed.entries) '${e.value} from ${e.key}',
      if (foreign.isNotEmpty) 'left ${foreign.length} unmappable',
    ];
    return parts.join(', ');
  }
}

/// Moves sibling-script characters into Devanagari.
///
/// Latin, digits, punctuation and whitespace pass through untouched — a Nepali
/// sentence may legitimately contain a product name or a number.
ScriptRepair repairDevanagari(String text) {
  final out = StringBuffer();
  final transposed = <String, int>{};
  final foreign = StringBuffer();

  for (final rune in text.runes) {
    final script = _blockOf(rune);
    if (script == null) {
      out.writeCharCode(rune);
      // Southern scripts reach here: not transposable, but still not
      // Devanagari, so the caller is told about them.
      if (_isBrahmicNonDevanagari(rune)) foreign.writeCharCode(rune);
      continue;
    }

    final base = _siblings[script]!;
    final offset = rune - base;
    if (_masks[script]!.toUnsigned(128) >> offset & BigInt.one == BigInt.one) {
      out.writeCharCode(_devanagariBase + offset);
      transposed[script] = (transposed[script] ?? 0) + 1;
    } else {
      out.writeCharCode(rune);
      foreign.writeCharCode(rune);
    }
  }

  return ScriptRepair(out.toString(), transposed, foreign.toString());
}

/// The sibling block [rune] belongs to, or null if it is not one of them.
String? _blockOf(int rune) {
  for (final e in _siblings.entries) {
    if (rune >= e.value && rune < e.value + 0x80) return e.key;
  }
  return null;
}

/// True when [text] contains no Brahmic characters outside Devanagari.
bool isDevanagariClean(String text) =>
    text.runes.every((r) => !_isBrahmicNonDevanagari(r));

/// The full Brahmic range, U+0980–U+0DFF: the sibling blocks plus the southern
/// scripts this deliberately does not transpose.
bool _isBrahmicNonDevanagari(int rune) => rune >= 0x0980 && rune <= 0x0DFF;

/// Repairs mixed-script text on its way into another engine.
///
/// Sits outside the synthesiser rather than inside it: the recogniser and the
/// captions want the model's actual words, and only the audio path needs the
/// repair.
class ScriptGuardTtsEngine implements TtsEngine {
  const ScriptGuardTtsEngine(this._inner, {this.onRepair});

  final TtsEngine _inner;

  /// Called whenever text had to be changed, so a caller can surface it. The
  /// repair is a workaround for a model defect, not a routine transform, and
  /// silently papering over it hides which models need replacing.
  final void Function(ScriptRepair)? onRepair;

  @override
  int get sampleRate => _inner.sampleRate;

  @override
  Stream<AudioChunk> synthesize(String text) {
    final repair = repairDevanagari(text);
    if (!repair.clean) onRepair?.call(repair);
    return _inner.synthesize(repair.text);
  }

  @override
  Future<void> dispose() => _inner.dispose();
}
