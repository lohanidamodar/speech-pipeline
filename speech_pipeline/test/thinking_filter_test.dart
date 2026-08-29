import 'package:speech_pipeline/speech_pipeline.dart';
import 'package:test/test.dart';

/// Feeds [chunks] through and returns everything emitted.
String run(List<String> chunks, {bool assumeLeading = false}) {
  final filter = ThinkingFilter(assumeLeadingThinking: assumeLeading);
  final out = StringBuffer();
  for (final chunk in chunks) {
    out.write(filter.add(chunk));
  }
  out.write(filter.flush());
  return out.toString();
}

void main() {
  group('inline reasoning', () {
    test('removes a well-formed block', () {
      expect(
        run(['<think>the user greeted me</think>Hello there!']),
        'Hello there!',
      );
    });

    test('removes it when the tag is split across deltas', () {
      // The whole reason this cannot be a replaceAll on each chunk.
      expect(
        run(['<th', 'ink>reason', 'ing</thi', 'nk>Kathmandu.']),
        'Kathmandu.',
      );
    });

    test('never emits a partial tag, even one character at a time', () {
      const input = '<think>hidden</think>Visible.';
      expect(run(input.split('')), 'Visible.');
    });

    test('keeps text on both sides of a block', () {
      expect(
        run(['Before ', '<think>x</think>', 'after.']),
        'Before after.',
      );
    });

    test('handles several blocks in one reply', () {
      expect(
        run(['<think>a</think>One. <think>b</think>Two.']),
        'One. Two.',
      );
    });

    test('passes ordinary text through untouched', () {
      expect(run(['The capital ', 'of Nepal ', 'is Kathmandu.']),
          'The capital of Nepal is Kathmandu.');
    });
  });

  group('text that merely looks like a tag', () {
    test('releases a partial tag that never completed', () {
      // "<thi" was ordinary text after all — swallowing it would silently eat
      // the end of a reply.
      expect(run(['Compare a < b and ', 'c <thi']), 'Compare a < b and c <thi');
    });

    test('does not hold back an unrelated angle bracket', () {
      expect(run(['2 < 3 is true.']), '2 < 3 is true.');
    });

    test('drops a stray closing tag rather than speaking it', () {
      // Models leak a bare </think> after a real block; reading the literal
      // characters aloud is the worst outcome.
      expect(
        run(['<think>r</think>Answer. </think> More.']),
        'Answer.  More.',
      );
    });
  });

  group('unclosed block', () {
    test('suppresses reasoning that was never closed', () {
      // A model that opened a block and stopped was thinking, not answering.
      expect(run(['<think>still reasoning when the stream ended']), '');
    });
  });

  group('assumeLeadingThinking', () {
    test('discards everything before a bare closing tag', () {
      // Nemotron-style: no opening tag, </think> used purely as a separator.
      expect(
        run(['reasoning about it</think>The answer is 4.'],
            assumeLeading: true),
        'The answer is 4.',
      );
    });

    test('keeps the reply when no closing tag ever arrives', () {
      expect(
        run(['Just a normal answer.'], assumeLeading: true),
        'Just a normal answer.',
      );
    });

    test('is off by default, because holding output costs latency', () {
      // Without the flag the text is emitted as it arrives; the stray tag is
      // still dropped rather than spoken.
      expect(
        run(['reasoning about it</think>The answer is 4.']),
        'reasoning about itThe answer is 4.',
      );
    });
  });

  group('withoutThinking', () {
    test('filters a stream', () async {
      final out = await withoutThinking(
        Stream.fromIterable(['<think>a', 'b</think>Hi', ' there']),
      ).join();
      expect(out, 'Hi there');
    });

    test('emits nothing rather than empty chunks while suppressing', () async {
      final chunks = await withoutThinking(
        Stream.fromIterable(['<think>', 'long reasoning', '</think>', 'Hi']),
      ).toList();
      expect(chunks.every((c) => c.isNotEmpty), isTrue);
      expect(chunks.join(), 'Hi');
    });
  });
}
