/// Removes inline reasoning from a streamed reply.
///
/// Disabling thinking at the server and ignoring `reasoning_content` only
/// covers the servers that separate the two. Many do not: llama.cpp run with
/// `--reasoning-format none`, and a good number of GGUF chat templates, emit
/// the model's scratchpad *inside* `content` as `<think>…</think>`. Passed
/// through, a voice assistant reads it aloud — which is the exact failure the
/// other defences exist to prevent.
///
/// This has to work on a stream, so a tag split across deltas — `<th` then
/// `ink>` — must not leak. Text that could still turn out to be the start of a
/// tag is held back until it is settled either way.
class ThinkingFilter {
  ThinkingFilter({this.assumeLeadingThinking = false});

  /// Treat a closing tag that never had an opening one as ending a block of
  /// reasoning, discarding everything before it.
  ///
  /// Some models — Nemotron among them — emit no opening tag and use
  /// `</think>` purely as a separator. Handling that in a stream means holding
  /// output back until a closing tag either arrives or clearly is not coming,
  /// which costs first-word latency. Off by default for that reason: the
  /// well-formed case below is free.
  final bool assumeLeadingThinking;

  static const _open = '<think>';
  static const _close = '</think>';

  bool _inThinking = false;
  bool _sawAnyTag = false;

  /// Text withheld because it might be a partial tag, or might turn out to
  /// have been reasoning.
  final _held = StringBuffer();

  /// Feeds [chunk] in and returns whatever is safe to emit.
  String add(String chunk) {
    _held.write(chunk);
    final out = StringBuffer();

    var text = _held.toString();
    var consumed = 0;

    while (consumed < text.length) {
      if (_inThinking) {
        final end = text.indexOf(_close, consumed);
        if (end < 0) {
          // Keep only what could still begin the closing tag.
          consumed = text.length - _partialSuffix(text, _close);
          break;
        }
        _inThinking = false;
        consumed = end + _close.length;
        continue;
      }

      final open = text.indexOf(_open, consumed);
      final close = text.indexOf(_close, consumed);

      // A closing tag before any opening one: everything so far was reasoning.
      if (close >= 0 && (open < 0 || close < open)) {
        if (assumeLeadingThinking && !_sawAnyTag) {
          _sawAnyTag = true;
          out.clear();
          consumed = close + _close.length;
          continue;
        }
        // Otherwise it is a stray tag, not a delimiter — emit the text before
        // it and drop the tag itself rather than letting it be spoken.
        out.write(text.substring(consumed, close));
        consumed = close + _close.length;
        continue;
      }

      if (open < 0) {
        // Emit everything except a tail that could start either tag.
        final keep = text.length -
            _partialSuffix(text, _open, alternative: _close);
        if (keep > consumed) out.write(text.substring(consumed, keep));
        consumed = keep;
        break;
      }

      out.write(text.substring(consumed, open));
      _inThinking = true;
      _sawAnyTag = true;
      consumed = open + _open.length;
    }

    text = text.substring(consumed);
    _held
      ..clear()
      ..write(text);

    // Until a leading block is ruled out, nothing may be emitted — it could
    // still turn out to have been reasoning.
    if (assumeLeadingThinking && !_sawAnyTag) {
      _held.write(out.toString());
      return '';
    }
    return out.toString();
  }

  /// Whatever is still held once the stream ends.
  ///
  /// A partial tag that never completed was ordinary text after all, so it is
  /// released rather than swallowed. Text held inside an unclosed `<think>`
  /// stays suppressed: a model that opened a block and stopped was reasoning.
  String flush() {
    final remainder = _held.toString();
    _held.clear();
    if (_inThinking) return '';
    if (assumeLeadingThinking && !_sawAnyTag) {
      // No closing tag ever came, so none of it was reasoning.
      return remainder;
    }
    return remainder;
  }

  /// Length of the suffix of [text] that could be the start of [tag] (or
  /// [alternative]), and so must not be emitted yet.
  static int _partialSuffix(String text, String tag, {String? alternative}) {
    var longest = 0;
    for (final candidate in [tag, if (alternative != null) alternative]) {
      final max = candidate.length - 1 < text.length
          ? candidate.length - 1
          : text.length;
      for (var n = max; n > 0; n--) {
        if (text.endsWith(candidate.substring(0, n))) {
          if (n > longest) longest = n;
          break;
        }
      }
    }
    return longest;
  }
}

/// Strips inline reasoning from [source].
Stream<String> withoutThinking(
  Stream<String> source, {
  bool assumeLeadingThinking = false,
}) async* {
  final filter = ThinkingFilter(assumeLeadingThinking: assumeLeadingThinking);
  await for (final chunk in source) {
    final out = filter.add(chunk);
    if (out.isNotEmpty) yield out;
  }
  final tail = filter.flush();
  if (tail.isNotEmpty) yield tail;
}
