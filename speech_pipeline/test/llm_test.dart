import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:speech_pipeline/speech_pipeline.dart';
import 'package:test/test.dart';

/// Serves canned SSE frames and records the request that asked for them.
({http.Client client, List<Map<String, dynamic>> bodies}) sseClient(
  List<String> frames, {
  int status = 200,
}) {
  final bodies = <Map<String, dynamic>>[];
  final client = MockClient.streaming((request, _) async {
    bodies.add(
      jsonDecode((request as http.Request).body) as Map<String, dynamic>,
    );
    final payload = frames.map((f) => 'data: $f\n\n').join();
    return http.StreamedResponse(
      Stream.value(utf8.encode(payload)),
      status,
      request: request,
    );
  });
  return (client: client, bodies: bodies);
}

String openAiFrame(Map<String, dynamic> delta) => jsonEncode({
  'choices': [
    {'delta': delta, 'index': 0},
  ],
});

void main() {
  group('OpenAiCompatibleLlm', () {
    test('assembles content deltas in order', () async {
      final m = sseClient([
        openAiFrame({'role': 'assistant'}),
        openAiFrame({'content': 'Hello'}),
        openAiFrame({'content': ' there'}),
        '[DONE]',
      ]);
      final llm = OpenAiCompatibleLlm(
        baseUrl: 'http://x/v1',
        model: 'm',
        client: m.client,
      );

      final out = await llm.respond([Message.user('hi')]).join();
      expect(out, 'Hello there');
    });

    test('never speaks reasoning aloud', () async {
      // The regression: Qwen3 streams its scratchpad as `reasoning_content`.
      // Reading that out would narrate the model thinking to itself.
      final m = sseClient([
        openAiFrame({'reasoning_content': 'The user greeted me, so I should'}),
        openAiFrame({'reasoning_content': ' greet them back. Let me think…'}),
        openAiFrame({'content': 'Hi!'}),
        '[DONE]',
      ]);
      final llm = OpenAiCompatibleLlm(
        baseUrl: 'http://x/v1',
        model: 'm',
        client: m.client,
      );

      expect(await llm.respond([Message.user('hi')]).join(), 'Hi!');
    });

    test('asks the server not to think, so the budget buys an answer', () async {
      // With thinking on and a voice-sized token budget, Qwen3 spent the whole
      // allowance reasoning and returned empty content on finish_reason=length.
      final m = sseClient([
        openAiFrame({'content': 'ok'}),
        '[DONE]',
      ]);
      await OpenAiCompatibleLlm(
        baseUrl: 'http://x/v1',
        model: 'm',
        disableThinking: true,
        client: m.client,
      ).respond([Message.user('hi')]).drain<void>();

      expect(m.bodies.single['reasoning_effort'], 'none');
      expect(
        (m.bodies.single['chat_template_kwargs']
            as Map<String, dynamic>)['enable_thinking'],
        isFalse,
      );
    });

    test(
      'sends no thinking knobs by default — a strict API would 400',
      () async {
        final m = sseClient([
          openAiFrame({'content': 'ok'}),
          '[DONE]',
        ]);
        await OpenAiCompatibleLlm(
          baseUrl: 'http://x/v1',
          model: 'm',
          client: m.client,
        ).respond([Message.user('hi')]).drain<void>();

        expect(m.bodies.single.containsKey('reasoning_effort'), isFalse);
        expect(m.bodies.single.containsKey('chat_template_kwargs'), isFalse);
      },
    );

    test('falls back to message.content when a proxy sends no delta', () async {
      final m = sseClient([
        jsonEncode({
          'choices': [
            {
              'message': {'content': 'proxied'},
              'index': 0,
            },
          ],
        }),
        '[DONE]',
      ]);
      final llm = OpenAiCompatibleLlm(
        baseUrl: 'http://x/v1',
        model: 'm',
        client: m.client,
      );

      expect(await llm.respond([Message.user('hi')]).join(), 'proxied');
    });

    test('survives keep-alive and partial frames', () async {
      final m = sseClient([
        '',
        'not json at all',
        openAiFrame({'content': 'a'}),
        '[DONE]',
      ]);
      final llm = OpenAiCompatibleLlm(
        baseUrl: 'http://x/v1',
        model: 'm',
        client: m.client,
      );

      expect(await llm.respond([Message.user('hi')]).join(), 'a');
    });

    test('reports a failed request instead of yielding silence', () async {
      final m = sseClient(['nope'], status: 401);
      final llm = OpenAiCompatibleLlm(
        baseUrl: 'http://x/v1',
        model: 'm',
        client: m.client,
      );

      expect(
        llm.respond([Message.user('hi')]).join(),
        throwsA(isA<LlmException>()),
      );
    });

    test('names the address when nothing answers', () async {
      // A bare "ClientException: Connection refused" tells the user neither
      // what was tried nor what to do about it.
      final client = MockClient.streaming((request, _) async {
        throw http.ClientException('Connection refused', request.url);
      });
      final llm = OpenAiCompatibleLlm(
        baseUrl: 'http://127.0.0.1:8081/v1',
        model: 'm',
        client: client,
      );

      await expectLater(
        llm.respond([Message.user('hi')]).join(),
        throwsA(
          isA<LlmUnreachable>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('127.0.0.1:8081'), contains('server running')),
          ),
        ),
      );
    });

    test('sends provider headers and omits an empty bearer', () async {
      final captured = <String, String>{};
      final client = MockClient.streaming((request, _) async {
        // http keeps the case the caller used; compare on lowercase keys.
        request.headers.forEach((k, v) => captured[k.toLowerCase()] = v);
        return http.StreamedResponse(
          Stream.value(utf8.encode('data: [DONE]\n\n')),
          200,
          request: request,
        );
      });
      await OpenAiCompatibleLlm(
        baseUrl: 'http://x/v1',
        model: 'm',
        extraHeaders: const {'X-Title': 'Speech Pipeline'},
        client: client,
      ).respond([Message.user('hi')]).drain<void>();

      expect(captured['x-title'], 'Speech Pipeline');
      expect(captured.containsKey('authorization'), isFalse);
    });
  });

  group('AnthropicLlm', () {
    String block(String type, Map<String, dynamic> delta) => jsonEncode({
      'type': 'content_block_delta',
      'delta': {'type': type, ...delta},
    });

    test('assembles text_delta events', () async {
      final m = sseClient([
        jsonEncode({'type': 'message_start'}),
        block('text_delta', {'text': 'Hello'}),
        block('text_delta', {'text': ' world'}),
        jsonEncode({'type': 'message_stop'}),
      ]);
      final llm = AnthropicLlm(apiKey: 'k', client: m.client);

      expect(await llm.respond([Message.user('hi')]).join(), 'Hello world');
    });

    test('skips thinking blocks', () async {
      final m = sseClient([
        block('thinking_delta', {'thinking': 'let me consider'}),
        block('text_delta', {'text': 'Answer'}),
      ]);
      final llm = AnthropicLlm(apiKey: 'k', client: m.client);

      expect(await llm.respond([Message.user('hi')]).join(), 'Answer');
    });

    test('reports an unreachable host the same way', () async {
      final client = MockClient.streaming((request, _) async {
        throw http.ClientException('Connection refused', request.url);
      });
      await expectLater(
        AnthropicLlm(
          apiKey: 'k',
          client: client,
        ).respond([Message.user('hi')]).join(),
        throwsA(isA<LlmUnreachable>()),
      );
    });

    test('hoists the system prompt out of the message list', () async {
      final m = sseClient([
        block('text_delta', {'text': 'x'}),
      ]);
      await AnthropicLlm(apiKey: 'k', client: m.client).respond([
        Message.system('Be brief.'),
        Message.user('hi'),
      ]).drain<void>();

      final body = m.bodies.single;
      expect(body['system'], 'Be brief.');
      expect(
        (body['messages'] as List).length,
        1,
        reason: 'the API rejects a system role inside messages',
      );
      expect(body['max_tokens'], isNotNull, reason: 'required by the API');
    });

    test(
      'raises a mid-stream error event rather than truncating quietly',
      () async {
        final m = sseClient([
          block('text_delta', {'text': 'partial'}),
          jsonEncode({
            'type': 'error',
            'error': {'type': 'overloaded_error', 'message': 'Overloaded'},
          }),
        ]);
        final llm = AnthropicLlm(apiKey: 'k', client: m.client);

        expect(
          llm.respond([Message.user('hi')]).join(),
          throwsA(isA<LlmException>()),
        );
      },
    );
  });

  group('LlmConfig', () {
    LlmProvider byId(String id) => llmProviderById(id)!;

    test('local providers are usable with no key', () {
      final cfg = LlmConfig(provider: byId('llamacpp'));
      expect(cfg.isConfigured, isTrue);
      expect(cfg.provider.isPrivate, isTrue);
    });

    test('cloud providers name what is missing', () {
      expect(LlmConfig(provider: byId('openai')).problem, contains('API key'));
      expect(LlmConfig(provider: byId('custom')).problem, contains('base URL'));
      expect(
        LlmConfig(provider: byId('custom'), baseUrl: 'http://h/v1').problem,
        contains('model'),
      );
    });

    test('strips trailing slashes so the path never doubles up', () {
      final cfg = LlmConfig(
        provider: byId('custom'),
        apiKey: 'k',
        model: 'm',
        baseUrl: 'http://host:1234/v1///',
      );
      expect(cfg.effectiveBaseUrl, 'http://host:1234/v1');
    });

    test('overrides fall back to the provider default', () {
      expect(LlmConfig(provider: byId('ollama')).effectiveModel, 'qwen3:1.7b');
      expect(
        LlmConfig(provider: byId('ollama'), model: 'gemma3').effectiveModel,
        'gemma3',
      );
    });

    test('only self-hosted providers get the llama.cpp thinking knobs', () {
      // OpenAI rejects unrecognised request fields, so these must not be sent
      // to every provider just because one family of models needs them.
      for (final p in llmProviders) {
        expect(
          p.thinkingToggle,
          p.locality != LlmLocality.cloud || p.id == 'custom',
          reason: p.id,
        );
      }
    });

    test('buildLlm picks the transport, not the label', () {
      expect(
        buildLlm(LlmConfig(provider: byId('anthropic'), apiKey: 'k')),
        isA<AnthropicLlm>(),
      );
      expect(
        buildLlm(LlmConfig(provider: byId('groq'), apiKey: 'k')),
        isA<OpenAiCompatibleLlm>(),
      );
    });

    test('refuses to build an unusable engine', () {
      expect(
        () => buildLlm(LlmConfig(provider: byId('openai'))),
        throwsA(isA<StateError>()),
      );
    });

    test('every catalog entry is complete enough to offer', () {
      for (final p in llmProviders) {
        expect(p.id, isNotEmpty);
        expect(p.label, isNotEmpty);
        if (!p.needsBaseUrl) {
          expect(p.baseUrl, startsWith('http'), reason: p.id);
          expect(p.defaultModel, isNotEmpty, reason: p.id);
        }
      }
      expect(
        llmProviders.map((p) => p.id).toSet().length,
        llmProviders.length,
        reason: 'ids are used as stored settings keys',
      );
    });
  });
}
