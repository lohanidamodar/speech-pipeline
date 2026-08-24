import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:speech_pipeline/speech_pipeline.dart';
import 'package:test/test.dart';

void main() {
  http.Client serving(Map<String, List<String>> byBaseUrl) =>
      MockClient((request) async {
        for (final entry in byBaseUrl.entries) {
          if (request.url.toString() == '${entry.key}/models') {
            return http.Response(
              jsonEncode({
                'data': [
                  for (final m in entry.value) {'id': m},
                ],
              }),
              200,
            );
          }
        }
        throw http.ClientException('Connection refused', request.url);
      });

  test('finds a server and the model it is serving', () async {
    final found = await discoverLocalLlms(
      endpoints: const [('llamacpp', 'http://127.0.0.1:8082/v1')],
      client: serving({
        'http://127.0.0.1:8082/v1': ['gemma3-4b'],
      }),
    );

    expect(found.single.baseUrl, 'http://127.0.0.1:8082/v1');
    expect(found.single.providerId, 'llamacpp');
    expect(found.single.models, ['gemma3-4b']);
  });

  test('skips the ports with nothing on them', () async {
    // The reason this exists: the default port was wrong and the only symptom
    // was "ClientException".
    final found = await discoverLocalLlms(
      endpoints: const [
        ('llamacpp', 'http://127.0.0.1:8080/v1'),
        ('llamacpp', 'http://127.0.0.1:8082/v1'),
      ],
      client: serving({
        'http://127.0.0.1:8082/v1': ['gemma3-4b'],
      }),
    );

    expect(found.map((s) => s.baseUrl), ['http://127.0.0.1:8082/v1']);
  });

  test(
    'returns nothing rather than throwing when the machine is bare',
    () async {
      expect(await discoverLocalLlms(client: serving(const {})), isEmpty);
    },
  );

  test('accepts a server that lists no models', () async {
    final found = await discoverLocalLlms(
      endpoints: const [('ollama', 'http://127.0.0.1:11434/v1')],
      client: MockClient(
        (_) async => http.Response(jsonEncode({'data': []}), 200),
      ),
    );
    expect(found.single.models, isEmpty);
    expect(found.single.label, 'Ollama (local)');
  });

  test('ignores a server that answers with something else', () async {
    final found = await discoverLocalLlms(
      endpoints: const [('custom', 'http://127.0.0.1:1234/v1')],
      client: MockClient((_) async => http.Response('<html>hi</html>', 200)),
    );
    expect(found, isEmpty, reason: 'not an OpenAI-compatible listing');
  });

  test('ignores a non-200, such as a proxy demanding auth', () async {
    final found = await discoverLocalLlms(
      endpoints: const [('custom', 'http://127.0.0.1:1234/v1')],
      client: MockClient((_) async => http.Response('nope', 401)),
    );
    expect(found, isEmpty);
  });

  test('every default endpoint names a real catalog provider', () {
    for (final (id, url) in defaultLocalEndpoints) {
      expect(llmProviderById(id), isNotNull, reason: id);
      expect(url, startsWith('http://127.0.0.1:'), reason: 'local only');
    }
  });
}
